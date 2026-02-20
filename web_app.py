#!/usr/bin/env python3
"""
Geotag Photos - FastAPI 웹 서버

브라우저에서 GPX 기반 자동 매칭 + 수동 위치 지정을 할 수 있는 웹 GUI를 제공합니다.

사용법:
    python web_app.py [/path/to/photos]
"""

import asyncio
import os
import sys
import webbrowser

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
from starlette.requests import Request

from geo_core import (
    DEFAULT_MAX_GAP_SECONDS,
    async_get_photo_metadata,
    async_scan_photos,
    async_write_gps,
    check_exiftool,
    find_image_files,
    get_gpx_track_geojson,
    get_thumbnail_base64,
    parse_gpx_files,
    interpolate_gps,
)

# ---------------------------------------------------------------------------
# 설정
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# photo_dir: 커맨드라인 인자로 받거나 스크립트 위치 사용
if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    PHOTO_DIR = os.path.abspath(sys.argv[1])
else:
    PHOTO_DIR = SCRIPT_DIR

GPX_DIR = os.path.join(PHOTO_DIR, "gpx")

# ---------------------------------------------------------------------------
# FastAPI 앱
# ---------------------------------------------------------------------------

app = FastAPI(title="Geotag Photos", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# 정적 파일 & 템플릿
app.mount("/static", StaticFiles(directory=os.path.join(SCRIPT_DIR, "static")), name="static")
templates = Jinja2Templates(directory=os.path.join(SCRIPT_DIR, "templates"))


# ---------------------------------------------------------------------------
# Pydantic 모델
# ---------------------------------------------------------------------------

class ManualGeotagRequest(BaseModel):
    filename: str
    lat: float
    lon: float
    ele: float = 0.0


class AutoGeotagRequest(BaseModel):
    filenames: list[str]
    max_gap: int = DEFAULT_MAX_GAP_SECONDS


class BatchManualGeotagRequest(BaseModel):
    items: list[ManualGeotagRequest]


# ---------------------------------------------------------------------------
# 라우트
# ---------------------------------------------------------------------------

@app.get("/")
async def index(request: Request):
    """메인 페이지"""
    return templates.TemplateResponse("index.html", {
        "request": request,
        "photo_dir": PHOTO_DIR,
    })


@app.get("/api/status")
async def api_status():
    """서버 상태 및 기본 정보"""
    ok, version = check_exiftool()
    return {
        "photo_dir": PHOTO_DIR,
        "gpx_dir": GPX_DIR,
        "gpx_available": os.path.isdir(GPX_DIR),
        "exiftool_ok": ok,
        "exiftool_version": version,
    }


@app.post("/api/scan")
async def api_scan(max_gap: int = DEFAULT_MAX_GAP_SECONDS):
    """사진 폴더를 스캔하여 메타데이터 + GPX 매칭 결과를 반환합니다."""
    if not os.path.isdir(PHOTO_DIR):
        return JSONResponse(
            status_code=400,
            content={"error": f"폴더가 존재하지 않습니다: {PHOTO_DIR}"},
        )

    result = await async_scan_photos(PHOTO_DIR, max_gap)

    # filepath를 응답에서 제거 (보안)
    for photo in result["photos"]:
        photo.pop("filepath", None)

    return result


@app.get("/api/thumbnail/{filename}")
async def api_thumbnail(filename: str):
    """사진 썸네일을 base64 JPEG로 반환합니다."""
    filepath = os.path.join(PHOTO_DIR, filename)
    if not os.path.isfile(filepath):
        return JSONResponse(status_code=404, content={"error": "파일 없음"})

    thumb = get_thumbnail_base64(filepath)
    if thumb is None:
        return JSONResponse(status_code=500, content={"error": "썸네일 생성 실패"})

    return {"thumbnail": thumb}


@app.get("/api/photo/{filename}")
async def api_photo(filename: str):
    """원본 사진 파일을 서빙합니다."""
    filepath = os.path.join(PHOTO_DIR, filename)
    if not os.path.isfile(filepath):
        return JSONResponse(status_code=404, content={"error": "파일 없음"})
    return FileResponse(filepath)


@app.get("/api/gpx-track")
async def api_gpx_track():
    """GPX 트랙을 GeoJSON으로 반환합니다."""
    if not os.path.isdir(GPX_DIR):
        return {"type": "FeatureCollection", "features": []}
    return get_gpx_track_geojson(GPX_DIR)


@app.post("/api/auto-geotag")
async def api_auto_geotag(req: AutoGeotagRequest):
    """
    선택된 사진들에 대해 GPX 기반 자동 매칭 후 GPS를 기록합니다.
    비동기적으로 여러 사진을 동시 처리합니다.
    """
    if not os.path.isdir(GPX_DIR):
        return JSONResponse(
            status_code=400,
            content={"error": "GPX 폴더가 없습니다"},
        )

    trackpoints = parse_gpx_files(GPX_DIR)
    if not trackpoints:
        return JSONResponse(
            status_code=400,
            content={"error": "유효한 트랙포인트가 없습니다"},
        )

    results = []

    async def process_one(filename):
        filepath = os.path.join(PHOTO_DIR, filename)
        if not os.path.isfile(filepath):
            return {"filename": filename, "success": False, "reason": "파일 없음"}

        meta = await async_get_photo_metadata(filepath)
        if meta["has_gps"]:
            return {"filename": filename, "success": False, "reason": "GPS 이미 존재",
                    "lat": meta["lat"], "lon": meta["lon"]}

        if meta["time"] is None:
            return {"filename": filename, "success": False, "reason": "촬영 시각 없음"}

        from datetime import datetime
        photo_time = datetime.fromisoformat(meta["time"])
        gps = interpolate_gps(trackpoints, photo_time, req.max_gap)

        if gps is None:
            return {"filename": filename, "success": False, "reason": "GPX 매칭 실패"}

        ok = await async_write_gps(filepath, gps["lat"], gps["lon"], gps["ele"])
        return {
            "filename": filename,
            "success": ok,
            "lat": gps["lat"],
            "lon": gps["lon"],
            "ele": gps["ele"],
            "reason": "GPS 기록 완료" if ok else "GPS 기록 실패",
        }

    tasks = [process_one(fn) for fn in req.filenames]
    results = await asyncio.gather(*tasks)

    return {"results": list(results)}


@app.post("/api/manual-geotag")
async def api_manual_geotag(req: ManualGeotagRequest):
    """수동으로 사진에 GPS 위치를 지정합니다."""
    filepath = os.path.join(PHOTO_DIR, req.filename)
    if not os.path.isfile(filepath):
        return JSONResponse(status_code=404, content={"error": "파일 없음"})

    ok = await async_write_gps(filepath, req.lat, req.lon, req.ele)
    if ok:
        return {"success": True, "filename": req.filename,
                "lat": req.lat, "lon": req.lon}
    else:
        return JSONResponse(
            status_code=500,
            content={"error": "GPS 기록 실패"},
        )


@app.post("/api/batch-manual-geotag")
async def api_batch_manual_geotag(req: BatchManualGeotagRequest):
    """여러 사진에 수동 GPS 위치를 일괄 지정합니다."""
    async def process_one(item):
        filepath = os.path.join(PHOTO_DIR, item.filename)
        if not os.path.isfile(filepath):
            return {"filename": item.filename, "success": False, "reason": "파일 없음"}
        ok = await async_write_gps(filepath, item.lat, item.lon, item.ele)
        return {
            "filename": item.filename,
            "success": ok,
            "lat": item.lat,
            "lon": item.lon,
        }

    tasks = [process_one(item) for item in req.items]
    results = await asyncio.gather(*tasks)
    return {"results": list(results)}


# ---------------------------------------------------------------------------
# 서버 실행
# ---------------------------------------------------------------------------

def open_browser():
    """서버 시작 후 브라우저를 엽니다."""
    import time
    time.sleep(1.0)
    webbrowser.open("http://localhost:8000")


if __name__ == "__main__":
    print(f"📸 Geotag Photos Web UI")
    print(f"   사진 폴더: {PHOTO_DIR}")
    print(f"   서버: http://localhost:8000")
    print()

    import threading
    threading.Thread(target=open_browser, daemon=True).start()

    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
