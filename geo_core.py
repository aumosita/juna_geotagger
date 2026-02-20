#!/usr/bin/env python3
"""
Geotag Photos - 핵심 로직 모듈

GPX 파싱, 메타데이터 읽기, GPS 보간, GPS 기록 등의 핵심 기능을 제공합니다.
CLI(geotag_photos.py)와 웹 서버(web_app.py) 양쪽에서 공유합니다.
"""

import asyncio
import base64
import glob
import io
import json
import os
import subprocess
from bisect import bisect_left
from datetime import datetime, timedelta, timezone

import gpxpy
from PIL import Image

try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass

# 지원하는 이미지 확장자
IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".heic", ".heif", ".png",
    ".tiff", ".tif", ".dng", ".arw", ".cr2", ".nef",
}

# 기본 최대 보간 허용 시간 (초) - 1시간
DEFAULT_MAX_GAP_SECONDS = 3600


# ---------------------------------------------------------------------------
# 동기 함수 (CLI용)
# ---------------------------------------------------------------------------

def check_exiftool():
    """exiftool이 설치되어 있는지 확인합니다."""
    try:
        result = subprocess.run(
            ["exiftool", "-ver"],
            capture_output=True, text=True, check=True,
        )
        return True, result.stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False, None


def parse_gpx_files(gpx_dir):
    """
    GPX 디렉토리 내 모든 .gpx 파일을 파싱하여
    시간순 정렬된 트랙포인트 리스트를 반환합니다.

    Returns:
        list of dict: [{"time": datetime, "lat": float, "lon": float, "ele": float}, ...]
    """
    trackpoints = []
    gpx_files = sorted(glob.glob(os.path.join(gpx_dir, "*.gpx")))

    if not gpx_files:
        return trackpoints

    for gpx_file in gpx_files:
        try:
            with open(gpx_file, "r", encoding="utf-8") as f:
                gpx = gpxpy.parse(f)
        except Exception:
            continue

        for track in gpx.tracks:
            for segment in track.segments:
                for point in segment.points:
                    if point.time is None:
                        continue
                    pt_time = point.time
                    if pt_time.tzinfo is None:
                        pt_time = pt_time.replace(tzinfo=timezone.utc)
                    else:
                        pt_time = pt_time.astimezone(timezone.utc)

                    trackpoints.append({
                        "time": pt_time,
                        "lat": point.latitude,
                        "lon": point.longitude,
                        "ele": point.elevation if point.elevation is not None else 0.0,
                    })

        for point in gpx.waypoints:
            if point.time is None:
                continue
            pt_time = point.time
            if pt_time.tzinfo is None:
                pt_time = pt_time.replace(tzinfo=timezone.utc)
            else:
                pt_time = pt_time.astimezone(timezone.utc)

            trackpoints.append({
                "time": pt_time,
                "lat": point.latitude,
                "lon": point.longitude,
                "ele": point.elevation if point.elevation is not None else 0.0,
            })

    trackpoints.sort(key=lambda p: p["time"])
    return trackpoints


def get_gpx_track_geojson(gpx_dir):
    """GPX 트랙을 GeoJSON FeatureCollection으로 변환합니다."""
    features = []
    gpx_files = sorted(glob.glob(os.path.join(gpx_dir, "*.gpx")))

    for gpx_file in gpx_files:
        try:
            with open(gpx_file, "r", encoding="utf-8") as f:
                gpx = gpxpy.parse(f)
        except Exception:
            continue

        for track in gpx.tracks:
            for segment in track.segments:
                coords = []
                for point in segment.points:
                    coords.append([point.longitude, point.latitude])
                if coords:
                    features.append({
                        "type": "Feature",
                        "properties": {
                            "name": track.name or os.path.basename(gpx_file),
                        },
                        "geometry": {
                            "type": "LineString",
                            "coordinates": coords,
                        },
                    })

    return {"type": "FeatureCollection", "features": features}


def _parse_exiftool_datetime(info):
    """exiftool JSON 출력에서 촬영 시각을 파싱합니다."""
    date_str = info.get("DateTimeOriginal") or info.get("CreateDate")
    if not date_str or date_str == "0000:00:00 00:00:00":
        return None

    offset_str = info.get("OffsetTimeOriginal") or info.get("OffsetTime")

    photo_time = None
    for fmt in ["%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y:%m:%d %H:%M:%S%z"]:
        try:
            photo_time = datetime.strptime(date_str.strip(), fmt)
            break
        except ValueError:
            continue

    if photo_time is None:
        try:
            photo_time = datetime.strptime(date_str.strip().split(".")[0], "%Y:%m:%d %H:%M:%S")
        except ValueError:
            return None

    if photo_time.tzinfo is None:
        if offset_str:
            try:
                offset_str = offset_str.strip()
                sign = 1 if offset_str[0] == "+" else -1
                parts = offset_str[1:].split(":")
                hours = int(parts[0])
                minutes = int(parts[1]) if len(parts) > 1 else 0
                offset = timezone(timedelta(hours=sign * hours, minutes=sign * minutes))
                photo_time = photo_time.replace(tzinfo=offset)
            except (ValueError, IndexError):
                pass

        if photo_time.tzinfo is None:
            photo_time = photo_time.astimezone()

    photo_time = photo_time.astimezone(timezone.utc)
    return photo_time


def get_photo_metadata(filepath):
    """
    exiftool로 사진의 촬영 시각과 GPS 정보를 읽습니다.

    Returns:
        dict: {"filename", "filepath", "time", "has_gps", "lat", "lon"}
    """
    filename = os.path.basename(filepath)
    result_dict = {
        "filename": filename,
        "filepath": filepath,
        "time": None,
        "has_gps": False,
        "lat": None,
        "lon": None,
    }
    try:
        result = subprocess.run(
            [
                "exiftool", "-j", "-n",
                "-DateTimeOriginal",
                "-CreateDate",
                "-OffsetTimeOriginal",
                "-OffsetTime",
                "-GPSLatitude",
                "-GPSLongitude",
                filepath,
            ],
            capture_output=True, text=True, check=True,
        )
        data = json.loads(result.stdout)
        if not data:
            return result_dict

        info = data[0]

        gps_lat = info.get("GPSLatitude")
        gps_lon = info.get("GPSLongitude")
        has_gps = gps_lat is not None and gps_lon is not None
        result_dict["has_gps"] = has_gps
        if has_gps:
            result_dict["lat"] = float(gps_lat)
            result_dict["lon"] = float(gps_lon)

        photo_time = _parse_exiftool_datetime(info)
        if photo_time:
            result_dict["time"] = photo_time.isoformat()

        return result_dict

    except (subprocess.CalledProcessError, json.JSONDecodeError, Exception):
        return result_dict


def interpolate_gps(trackpoints, photo_time, max_gap_seconds):
    """
    트랙포인트 리스트에서 사진 촬영 시각에 해당하는 GPS 위치를
    선형 보간으로 계산합니다.

    Returns:
        dict or None: {"lat": float, "lon": float, "ele": float}
    """
    if not trackpoints:
        return None

    times = [p["time"] for p in trackpoints]
    idx = bisect_left(times, photo_time)

    if idx < len(trackpoints) and trackpoints[idx]["time"] == photo_time:
        p = trackpoints[idx]
        return {"lat": p["lat"], "lon": p["lon"], "ele": p["ele"]}

    if idx == 0:
        gap = (trackpoints[0]["time"] - photo_time).total_seconds()
        if gap <= max_gap_seconds:
            p = trackpoints[0]
            return {"lat": p["lat"], "lon": p["lon"], "ele": p["ele"]}
        return None

    if idx >= len(trackpoints):
        gap = (photo_time - trackpoints[-1]["time"]).total_seconds()
        if gap <= max_gap_seconds:
            p = trackpoints[-1]
            return {"lat": p["lat"], "lon": p["lon"], "ele": p["ele"]}
        return None

    before = trackpoints[idx - 1]
    after = trackpoints[idx]
    total_gap = (after["time"] - before["time"]).total_seconds()

    if total_gap > max_gap_seconds:
        return None
    if total_gap == 0:
        return {"lat": before["lat"], "lon": before["lon"], "ele": before["ele"]}

    elapsed = (photo_time - before["time"]).total_seconds()
    ratio = elapsed / total_gap

    lat = before["lat"] + (after["lat"] - before["lat"]) * ratio
    lon = before["lon"] + (after["lon"] - before["lon"]) * ratio
    ele = before["ele"] + (after["ele"] - before["ele"]) * ratio

    return {"lat": lat, "lon": lon, "ele": ele}


def write_gps_with_exiftool(filepath, lat, lon, ele=0.0):
    """exiftool을 사용하여 사진 파일에 GPS 메타데이터를 기록합니다."""
    lat_ref = "N" if lat >= 0 else "S"
    lon_ref = "E" if lon >= 0 else "W"
    ele_ref = 0 if ele >= 0 else 1

    args = [
        "exiftool",
        "-overwrite_original",
        f"-GPSLatitude={abs(lat)}",
        f"-GPSLatitudeRef={lat_ref}",
        f"-GPSLongitude={abs(lon)}",
        f"-GPSLongitudeRef={lon_ref}",
        f"-GPSAltitude={abs(ele)}",
        f"-GPSAltitudeRef={ele_ref}",
        filepath,
    ]
    try:
        subprocess.run(args, capture_output=True, text=True, check=True)
        return True
    except subprocess.CalledProcessError:
        return False


def find_image_files(photo_dir):
    """대상 디렉토리에서 이미지 파일들을 찾습니다."""
    image_files = []
    for entry in sorted(os.listdir(photo_dir)):
        if entry.lower() in ("gpx", "no_gps", ".venv", "__pycache__",
                              "static", "templates", "node_modules"):
            continue
        filepath = os.path.join(photo_dir, entry)
        if not os.path.isfile(filepath):
            continue
        ext = os.path.splitext(entry)[1].lower()
        if ext in IMAGE_EXTENSIONS:
            image_files.append(filepath)
    return image_files


def get_thumbnail_base64(filepath, size=(200, 200)):
    """사진의 썸네일을 base64 인코딩된 JPEG로 반환합니다."""
    try:
        with Image.open(filepath) as img:
            img.thumbnail(size)
            if img.mode in ("RGBA", "P"):
                img = img.convert("RGB")
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=70)
            return base64.b64encode(buf.getvalue()).decode("utf-8")
    except Exception:
        return None


# ---------------------------------------------------------------------------
# 비동기 함수 (웹 서버용)
# ---------------------------------------------------------------------------

async def async_get_photo_metadata(filepath):
    """exiftool을 비동기적으로 호출하여 사진 메타데이터를 읽습니다."""
    filename = os.path.basename(filepath)
    result_dict = {
        "filename": filename,
        "filepath": filepath,
        "time": None,
        "has_gps": False,
        "lat": None,
        "lon": None,
    }
    try:
        proc = await asyncio.create_subprocess_exec(
            "exiftool", "-j", "-n",
            "-DateTimeOriginal",
            "-CreateDate",
            "-OffsetTimeOriginal",
            "-OffsetTime",
            "-GPSLatitude",
            "-GPSLongitude",
            filepath,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await proc.communicate()

        if proc.returncode != 0:
            return result_dict

        data = json.loads(stdout.decode("utf-8"))
        if not data:
            return result_dict

        info = data[0]

        gps_lat = info.get("GPSLatitude")
        gps_lon = info.get("GPSLongitude")
        has_gps = gps_lat is not None and gps_lon is not None
        result_dict["has_gps"] = has_gps
        if has_gps:
            result_dict["lat"] = float(gps_lat)
            result_dict["lon"] = float(gps_lon)

        photo_time = _parse_exiftool_datetime(info)
        if photo_time:
            result_dict["time"] = photo_time.isoformat()

        return result_dict

    except Exception:
        return result_dict


async def async_write_gps(filepath, lat, lon, ele=0.0):
    """GPS 기록을 비동기적으로 수행합니다."""
    lat_ref = "N" if lat >= 0 else "S"
    lon_ref = "E" if lon >= 0 else "W"
    ele_ref = "0" if ele >= 0 else "1"

    proc = await asyncio.create_subprocess_exec(
        "exiftool",
        "-overwrite_original",
        f"-GPSLatitude={abs(lat)}",
        f"-GPSLatitudeRef={lat_ref}",
        f"-GPSLongitude={abs(lon)}",
        f"-GPSLongitudeRef={lon_ref}",
        f"-GPSAltitude={abs(ele)}",
        f"-GPSAltitudeRef={ele_ref}",
        filepath,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    return proc.returncode == 0


async def async_scan_photos(photo_dir, max_gap=DEFAULT_MAX_GAP_SECONDS):
    """
    사진 폴더를 비동기적으로 스캔하여 메타데이터를 수집하고
    GPX 매칭을 수행합니다.
    """
    gpx_dir = os.path.join(photo_dir, "gpx")
    image_files = find_image_files(photo_dir)

    # GPX 파싱 (동기 - 빠름)
    trackpoints = []
    gpx_geojson = {"type": "FeatureCollection", "features": []}
    if os.path.isdir(gpx_dir):
        trackpoints = parse_gpx_files(gpx_dir)
        gpx_geojson = get_gpx_track_geojson(gpx_dir)

    # 비동기로 메타데이터 읽기
    tasks = [async_get_photo_metadata(fp) for fp in image_files]
    photos = await asyncio.gather(*tasks)

    # GPX 매칭
    for photo in photos:
        if photo["has_gps"]:
            photo["status"] = "has_gps"
            continue

        if photo["time"] is None:
            photo["status"] = "no_time"
            continue

        photo_time = datetime.fromisoformat(photo["time"])
        gps = interpolate_gps(trackpoints, photo_time, max_gap)
        if gps:
            photo["matched_lat"] = gps["lat"]
            photo["matched_lon"] = gps["lon"]
            photo["matched_ele"] = gps["ele"]
            photo["status"] = "matched"
        else:
            photo["status"] = "no_match"

    return {
        "photos": photos,
        "gpx_geojson": gpx_geojson,
        "trackpoint_count": len(trackpoints),
        "gpx_available": os.path.isdir(gpx_dir),
    }
