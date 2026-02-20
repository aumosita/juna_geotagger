#!/usr/bin/env python3
"""
GPX 기반 사진 위치정보(Geotag) 삽입 스크립트 (CLI)

사진 폴더 내 gpx/ 서브폴더에 있는 GPX 파일들의 트랙 포인트를 이용하여,
GPS 정보가 없는 사진에 시간 기반 선형 보간으로 위치를 계산하고
exiftool을 사용해 EXIF 메타데이터에 기록합니다.

사용법:
    python geotag_photos.py [/path/to/photos] [--max-gap 3600] [--dry-run]
"""

import argparse
import os
import shutil
import sys
from datetime import datetime

from geo_core import (
    DEFAULT_MAX_GAP_SECONDS,
    check_exiftool,
    find_image_files,
    get_photo_metadata,
    interpolate_gps,
    parse_gpx_files,
    write_gps_with_exiftool,
)


def main():
    parser = argparse.ArgumentParser(
        description="GPX 파일을 이용해 사진에 GPS 위치정보를 기록합니다.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
예시:
    python geotag_photos.py /path/to/photos
    python geotag_photos.py /path/to/photos --max-gap 7200
    python geotag_photos.py /path/to/photos --dry-run

폴더 구조:
    /path/to/photos/
    ├── IMG_001.jpg
    ├── IMG_002.heic
    ├── gpx/
    │   ├── track1.gpx
    │   └── track2.gpx
    └── no_gps/          ← 매칭 실패 사진 이동
        """,
    )
    parser.add_argument(
        "photo_dir",
        nargs="?",
        default=os.path.dirname(os.path.abspath(__file__)),
        help="사진이 들어있는 폴더 경로 (gpx/ 서브폴더 포함, 기본값: 스크립트 위치)",
    )
    parser.add_argument(
        "--max-gap",
        type=int,
        default=DEFAULT_MAX_GAP_SECONDS,
        help=f"보간 허용 최대 시간 차이 (초, 기본값: {DEFAULT_MAX_GAP_SECONDS})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="실제로 파일을 수정하지 않고 결과만 미리 봅니다",
    )

    args = parser.parse_args()

    photo_dir = os.path.abspath(args.photo_dir)
    gpx_dir = os.path.join(photo_dir, "gpx")
    no_gps_dir = os.path.join(photo_dir, "no_gps")
    max_gap = args.max_gap
    dry_run = args.dry_run

    # 유효성 검사
    if not os.path.isdir(photo_dir):
        print(f"오류: '{photo_dir}' 폴더가 존재하지 않습니다.")
        sys.exit(1)

    if not os.path.isdir(gpx_dir):
        print(f"오류: '{gpx_dir}' 폴더가 존재하지 않습니다.")
        print("  사진 폴더 안에 'gpx' 폴더를 만들고 GPX 파일을 넣어주세요.")
        sys.exit(1)

    print("=" * 60)
    print("GPX 기반 사진 위치정보 삽입")
    print("=" * 60)
    print(f"  사진 폴더: {photo_dir}")
    print(f"  GPX 폴더:  {gpx_dir}")
    print(f"  최대 보간 허용 시간: {max_gap}초 ({max_gap / 60:.0f}분)")
    if dry_run:
        print("  ⚠️  DRY RUN 모드 - 파일을 수정하지 않습니다")
    print()

    # exiftool 확인
    print("[1/4] exiftool 확인 중...")
    ok, version = check_exiftool()
    if not ok:
        print("오류: exiftool이 설치되어 있지 않습니다.")
        print("  macOS: brew install exiftool")
        print("  Linux: sudo apt install libimage-exiftool-perl")
        sys.exit(1)
    print(f"  exiftool 버전: {version}")
    print()

    # GPX 파일 파싱
    print("[2/4] GPX 파일 파싱 중...")
    trackpoints = parse_gpx_files(gpx_dir)
    if not trackpoints:
        print("오류: 유효한 트랙포인트가 없습니다.")
        sys.exit(1)
    print(f"  총 {len(trackpoints)}개의 트랙포인트 로드 완료")
    print(f"  GPX 시간 범위: {trackpoints[0]['time']} ~ {trackpoints[-1]['time']}")
    print()

    # 이미지 파일 탐색
    print("[3/4] 이미지 파일 탐색 중...")
    image_files = find_image_files(photo_dir)
    print(f"  {len(image_files)}개의 이미지 파일 발견")
    if not image_files:
        print("  처리할 이미지 파일이 없습니다.")
        sys.exit(0)
    print()

    # GPS 정보 기록
    print("[4/4] GPS 정보 처리 중...")
    print("-" * 60)

    stats = {
        "total": len(image_files),
        "already_gps": 0,
        "tagged": 0,
        "no_datetime": 0,
        "no_match": 0,
        "errors": 0,
    }
    no_gps_files = []

    for i, filepath in enumerate(image_files, 1):
        filename = os.path.basename(filepath)
        print(f"\n  [{i}/{len(image_files)}] {filename}")

        # 메타데이터 읽기
        meta = get_photo_metadata(filepath)

        if meta["has_gps"]:
            print("    ✓ GPS 정보 이미 존재 — 건너뜀")
            stats["already_gps"] += 1
            continue

        if meta["time"] is None:
            print("    ✗ 촬영 시각 정보 없음")
            stats["no_datetime"] += 1
            no_gps_files.append((filepath, "촬영 시각 없음"))
            continue

        photo_time = datetime.fromisoformat(meta["time"])
        print(f"    촬영 시각: {photo_time.isoformat()}")

        gps = interpolate_gps(trackpoints, photo_time, max_gap)

        if gps is None:
            print("    ✗ GPX 시간 범위 밖 또는 갭 초과 — 매칭 실패")
            stats["no_match"] += 1
            no_gps_files.append((filepath, "GPX 시간 범위 밖"))
            continue

        print(f"    → 위도: {gps['lat']:.6f}, 경도: {gps['lon']:.6f}, 고도: {gps['ele']:.1f}m")

        if dry_run:
            print("    [DRY RUN] GPS 기록 건너뜀")
            stats["tagged"] += 1
        else:
            success = write_gps_with_exiftool(filepath, gps["lat"], gps["lon"], gps["ele"])
            if success:
                print("    ✓ GPS 기록 완료")
                stats["tagged"] += 1
            else:
                stats["errors"] += 1

    print()
    print("-" * 60)

    # 매칭 실패 사진 이동
    if no_gps_files:
        print(f"\n매칭 실패 사진 {len(no_gps_files)}개를 '{os.path.basename(no_gps_dir)}/' 폴더로 이동합니다...")
        if not dry_run:
            os.makedirs(no_gps_dir, exist_ok=True)
        for filepath, reason in no_gps_files:
            dest = os.path.join(no_gps_dir, os.path.basename(filepath))
            if dry_run:
                print(f"  [DRY RUN] {os.path.basename(filepath)} → no_gps/ ({reason})")
            else:
                try:
                    shutil.move(filepath, dest)
                    print(f"  {os.path.basename(filepath)} → no_gps/ ({reason})")
                except Exception as e:
                    print(f"  오류: {os.path.basename(filepath)} 이동 실패 - {e}")

    # 결과 요약
    print()
    print("=" * 60)
    print("결과 요약")
    print("=" * 60)
    print(f"  전체 이미지:       {stats['total']}개")
    print(f"  GPS 이미 존재:     {stats['already_gps']}개 (건너뜀)")
    print(f"  GPS 기록 성공:     {stats['tagged']}개 ✓")
    print(f"  촬영 시각 없음:    {stats['no_datetime']}개 → no_gps/")
    print(f"  GPX 매칭 실패:     {stats['no_match']}개 → no_gps/")
    if stats["errors"]:
        print(f"  오류 발생:         {stats['errors']}개")
    print("=" * 60)


if __name__ == "__main__":
    main()
