/* ========================================================
   Geotag Photos – Frontend Application
   ======================================================== */

(() => {
    'use strict';

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    const state = {
        photos: [],
        selectedFiles: new Set(),
        filter: 'all',
        thumbnailCache: {},
        mapMode: null, // null | 'click-assign'
        mapMarkers: {},
        gpxLayer: null,
    };

    // ------------------------------------------------------------------
    // DOM refs
    // ------------------------------------------------------------------
    const $ = (sel) => document.querySelector(sel);
    const dom = {
        photoDirLabel: $('#photo-dir-label'),
        exiftoolStatus: $('#exiftool-status'),
        btnScan: $('#btn-scan'),
        btnAutoGeotag: $('#btn-auto-geotag'),
        btnSelectAll: $('#btn-select-all'),
        tabBar: $('#tab-bar'),
        photoGrid: $('#photo-grid'),
        emptyState: $('#empty-state'),
        mapInstructions: $('#map-instructions'),
        instructionsText: $('#instructions-text'),
        btnCancelMode: $('#btn-cancel-mode'),
        progressBar: $('#progress-bar'),
        progressFill: $('#progress-fill'),
        toastContainer: $('#toast-container'),
        modal: $('#confirm-modal'),
        modalTitle: $('#modal-title'),
        modalMessage: $('#modal-message'),
        modalPreview: $('#modal-preview'),
        modalCancel: $('#modal-cancel'),
        modalConfirm: $('#modal-confirm'),
    };

    // ------------------------------------------------------------------
    // Map
    // ------------------------------------------------------------------
    const map = L.map('map', {
        center: [37.5665, 126.978],
        zoom: 6,
        zoomControl: true,
    });

    L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; <a href="https://carto.com/">CARTO</a>',
        subdomains: 'abcd',
        maxZoom: 19,
    }).addTo(map);

    // Custom icons
    const iconGps = L.divIcon({
        className: 'marker-gps',
        html: '<div style="width:12px;height:12px;background:#00cec9;border:2px solid #fff;border-radius:50%;box-shadow:0 0 8px rgba(0,206,201,0.6)"></div>',
        iconSize: [12, 12],
        iconAnchor: [6, 6],
    });

    const iconMatched = L.divIcon({
        className: 'marker-matched',
        html: '<div style="width:14px;height:14px;background:#6c5ce7;border:2px solid #fff;border-radius:50%;box-shadow:0 0 10px rgba(108,92,231,0.6);animation:pulse 2s infinite"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
    });

    const iconManual = L.divIcon({
        className: 'marker-manual',
        html: '<div style="width:14px;height:14px;background:#fdcb6e;border:2px solid #fff;border-radius:50%;box-shadow:0 0 10px rgba(253,203,110,0.6)"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
    });

    // ------------------------------------------------------------------
    // API helpers
    // ------------------------------------------------------------------
    async function api(method, url, body = null) {
        const opts = { method, headers: {} };
        if (body) {
            opts.headers['Content-Type'] = 'application/json';
            opts.body = JSON.stringify(body);
        }
        const res = await fetch(url, opts);
        return res.json();
    }

    // ------------------------------------------------------------------
    // Toasts
    // ------------------------------------------------------------------
    function showToast(msg, type = 'info', duration = 3500) {
        const el = document.createElement('div');
        el.className = `toast ${type}`;
        el.textContent = msg;
        dom.toastContainer.appendChild(el);
        setTimeout(() => {
            el.classList.add('fadeout');
            setTimeout(() => el.remove(), 300);
        }, duration);
    }

    // ------------------------------------------------------------------
    // Progress
    // ------------------------------------------------------------------
    function showProgress(pct) {
        dom.progressBar.classList.remove('hidden');
        dom.progressFill.style.width = `${pct}%`;
    }

    function hideProgress() {
        dom.progressFill.style.width = '100%';
        setTimeout(() => {
            dom.progressBar.classList.add('hidden');
            dom.progressFill.style.width = '0%';
        }, 400);
    }

    // ------------------------------------------------------------------
    // Modal
    // ------------------------------------------------------------------
    function showModal(title, message, previewHtml = '') {
        return new Promise((resolve) => {
            dom.modalTitle.textContent = title;
            dom.modalMessage.textContent = message;
            dom.modalPreview.innerHTML = previewHtml;
            dom.modal.classList.remove('hidden');

            const cleanup = () => {
                dom.modal.classList.add('hidden');
                dom.modalConfirm.removeEventListener('click', onConfirm);
                dom.modalCancel.removeEventListener('click', onCancel);
            };
            const onConfirm = () => { cleanup(); resolve(true); };
            const onCancel = () => { cleanup(); resolve(false); };

            dom.modalConfirm.addEventListener('click', onConfirm);
            dom.modalCancel.addEventListener('click', onCancel);
        });
    }

    // ------------------------------------------------------------------
    // Init
    // ------------------------------------------------------------------
    async function init() {
        // Server status
        const status = await api('GET', '/api/status');
        dom.photoDirLabel.textContent = status.photo_dir;

        if (status.exiftool_ok) {
            dom.exiftoolStatus.textContent = `exiftool ${status.exiftool_version}`;
            dom.exiftoolStatus.classList.remove('error');
        } else {
            dom.exiftoolStatus.textContent = 'exiftool 없음';
            dom.exiftoolStatus.classList.add('error');
        }

        // Event listeners
        dom.btnScan.addEventListener('click', scanPhotos);
        dom.btnAutoGeotag.addEventListener('click', autoGeotag);
        dom.btnSelectAll.addEventListener('click', toggleSelectAll);
        dom.btnCancelMode.addEventListener('click', cancelMapMode);

        dom.tabBar.addEventListener('click', (e) => {
            const tab = e.target.closest('.tab');
            if (!tab) return;
            dom.tabBar.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            tab.classList.add('active');
            state.filter = tab.dataset.filter;
            renderPhotos();
        });

        // Map click handler
        map.on('click', onMapClick);

        // Drag-and-drop on map
        const mapEl = document.getElementById('panel-map');
        mapEl.addEventListener('dragover', (e) => {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'copy';
            mapEl.classList.add('drop-active');
        });
        mapEl.addEventListener('dragleave', () => {
            mapEl.classList.remove('drop-active');
        });
        mapEl.addEventListener('drop', onMapDrop);

        // Auto-scan on load
        await scanPhotos();
    }

    // ------------------------------------------------------------------
    // Scan
    // ------------------------------------------------------------------
    async function scanPhotos() {
        dom.btnScan.disabled = true;
        dom.btnScan.textContent = '⏳ 스캔 중...';
        showProgress(10);

        try {
            const data = await api('POST', '/api/scan');
            state.photos = data.photos || [];

            showProgress(50);

            // Render GPX track
            if (state.gpxLayer) {
                map.removeLayer(state.gpxLayer);
            }
            if (data.gpx_geojson && data.gpx_geojson.features.length > 0) {
                state.gpxLayer = L.geoJSON(data.gpx_geojson, {
                    style: {
                        color: '#6c5ce7',
                        weight: 3,
                        opacity: 0.7,
                    },
                }).addTo(map);
                map.fitBounds(state.gpxLayer.getBounds(), { padding: [40, 40] });
            }

            // Clear existing markers
            Object.values(state.mapMarkers).forEach(m => map.removeLayer(m));
            state.mapMarkers = {};

            // Add markers for photos with GPS
            for (const photo of state.photos) {
                if (photo.has_gps && photo.lat != null && photo.lon != null) {
                    addPhotoMarker(photo.filename, photo.lat, photo.lon, iconGps);
                }
                if (photo.status === 'matched' && photo.matched_lat != null) {
                    addPhotoMarker(photo.filename, photo.matched_lat, photo.matched_lon, iconMatched);
                }
            }

            showProgress(80);

            // Load thumbnails in parallel (batch)
            await loadThumbnails();

            renderPhotos();
            updateCounts();
            hideProgress();

            const noGps = state.photos.filter(p => !p.has_gps).length;
            showToast(`${state.photos.length}개 사진 발견 (GPS 없음: ${noGps}개)`, 'info');
        } catch (e) {
            showToast('스캔 실패: ' + e.message, 'error');
            hideProgress();
        } finally {
            dom.btnScan.disabled = false;
            dom.btnScan.textContent = '🔍 스캔';
        }
    }

    // ------------------------------------------------------------------
    // Thumbnails
    // ------------------------------------------------------------------
    async function loadThumbnails() {
        const batch = state.photos.filter(p => !state.thumbnailCache[p.filename]);
        const CONCURRENCY = 6;

        for (let i = 0; i < batch.length; i += CONCURRENCY) {
            const chunk = batch.slice(i, i + CONCURRENCY);
            const results = await Promise.allSettled(
                chunk.map(async (p) => {
                    const data = await api('GET', `/api/thumbnail/${encodeURIComponent(p.filename)}`);
                    if (data.thumbnail) {
                        state.thumbnailCache[p.filename] = `data:image/jpeg;base64,${data.thumbnail}`;
                    }
                })
            );
            // Update progress
            const pct = 80 + Math.round((i / batch.length) * 20);
            showProgress(pct);
        }
    }

    // ------------------------------------------------------------------
    // Render photo grid
    // ------------------------------------------------------------------
    function renderPhotos() {
        const filtered = state.photos.filter(p => {
            if (state.filter === 'all') return true;
            if (state.filter === 'no_gps') return !p.has_gps && p.status !== 'matched';
            if (state.filter === 'has_gps') return p.has_gps;
            if (state.filter === 'matched') return p.status === 'matched';
            return true;
        });

        if (filtered.length === 0) {
            dom.photoGrid.innerHTML = '';
            dom.photoGrid.appendChild(createEmptyState());
            dom.btnAutoGeotag.disabled = true;
            return;
        }

        dom.photoGrid.innerHTML = '';

        for (const photo of filtered) {
            const card = document.createElement('div');
            card.className = 'photo-card';
            card.dataset.filename = photo.filename;
            if (state.selectedFiles.has(photo.filename)) {
                card.classList.add('selected');
            }

            // Draggable
            card.draggable = true;
            card.addEventListener('dragstart', (e) => {
                e.dataTransfer.setData('text/plain', photo.filename);
                card.classList.add('dragging');
            });
            card.addEventListener('dragend', () => {
                card.classList.remove('dragging');
                document.getElementById('panel-map').classList.remove('drop-active');
            });

            // Status emoji
            let statusEmoji = '';
            if (photo.has_gps) statusEmoji = '📍';
            else if (photo.status === 'matched') statusEmoji = '⚡';
            else if (photo.status === 'no_time') statusEmoji = '⏱️';
            else statusEmoji = '❌';

            // Thumbnail
            const thumbSrc = state.thumbnailCache[photo.filename] || '';
            const imgTag = thumbSrc
                ? `<img src="${thumbSrc}" alt="${photo.filename}" loading="lazy">`
                : `<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;color:var(--text-muted);font-size:24px">📷</div>`;

            card.innerHTML = `
                ${imgTag}
                <div class="photo-checkbox">${state.selectedFiles.has(photo.filename) ? '✓' : ''}</div>
                <div class="photo-status">${statusEmoji}</div>
                <div class="photo-overlay">${photo.filename}</div>
            `;

            card.addEventListener('click', (e) => {
                if (e.shiftKey) {
                    // Shift-click: range select (simplified: toggle)
                    toggleSelect(photo.filename);
                } else if (e.metaKey || e.ctrlKey) {
                    toggleSelect(photo.filename);
                } else {
                    // Single click: select only this one
                    state.selectedFiles.clear();
                    toggleSelect(photo.filename);
                }
                renderPhotos();
                updateAutoGeotagButton();
            });

            // Double-click: enter click-assign mode
            card.addEventListener('dblclick', (e) => {
                e.preventDefault();
                state.selectedFiles.clear();
                state.selectedFiles.add(photo.filename);
                enterClickAssignMode();
                renderPhotos();
            });

            dom.photoGrid.appendChild(card);
        }
    }

    function createEmptyState() {
        const div = document.createElement('div');
        div.className = 'empty-state';
        div.innerHTML = `
            <span class="empty-icon">${state.photos.length === 0 ? '📁' : '🔍'}</span>
            <p>${state.photos.length === 0 ? '🔍 스캔 버튼을 눌러 사진을 불러오세요' : '이 필터에 해당하는 사진이 없습니다'}</p>
        `;
        return div;
    }

    function updateCounts() {
        const all = state.photos.length;
        const noGps = state.photos.filter(p => !p.has_gps && p.status !== 'matched').length;
        const hasGps = state.photos.filter(p => p.has_gps).length;
        const matched = state.photos.filter(p => p.status === 'matched').length;

        document.getElementById('count-all').textContent = all;
        document.getElementById('count-no-gps').textContent = noGps;
        document.getElementById('count-has-gps').textContent = hasGps;
        document.getElementById('count-matched').textContent = matched;
    }

    // ------------------------------------------------------------------
    // Selection
    // ------------------------------------------------------------------
    function toggleSelect(filename) {
        if (state.selectedFiles.has(filename)) {
            state.selectedFiles.delete(filename);
        } else {
            state.selectedFiles.add(filename);
        }
        updateAutoGeotagButton();
    }

    function toggleSelectAll() {
        const filtered = getFilteredPhotos();
        const allSelected = filtered.every(p => state.selectedFiles.has(p.filename));
        if (allSelected) {
            filtered.forEach(p => state.selectedFiles.delete(p.filename));
        } else {
            filtered.forEach(p => state.selectedFiles.add(p.filename));
        }
        renderPhotos();
        updateAutoGeotagButton();
    }

    function getFilteredPhotos() {
        return state.photos.filter(p => {
            if (state.filter === 'all') return true;
            if (state.filter === 'no_gps') return !p.has_gps && p.status !== 'matched';
            if (state.filter === 'has_gps') return p.has_gps;
            if (state.filter === 'matched') return p.status === 'matched';
            return true;
        });
    }

    function updateAutoGeotagButton() {
        const selected = state.selectedFiles.size;
        dom.btnAutoGeotag.disabled = selected === 0;
        dom.btnAutoGeotag.textContent = selected > 0
            ? `⚡ 자동 매칭 (${selected})`
            : '⚡ 자동 매칭';
    }

    // ------------------------------------------------------------------
    // Auto Geotag
    // ------------------------------------------------------------------
    async function autoGeotag() {
        const filenames = [...state.selectedFiles];
        if (filenames.length === 0) return;

        const confirmed = await showModal(
            '자동 GPS 매칭',
            `선택한 ${filenames.length}개의 사진에 GPX 트랙 기반으로 GPS를 기록합니다.`,
        );
        if (!confirmed) return;

        dom.btnAutoGeotag.disabled = true;
        showProgress(10);

        try {
            const data = await api('POST', '/api/auto-geotag', { filenames });
            const results = data.results || [];

            let successCount = 0;
            for (const r of results) {
                if (r.success) {
                    successCount++;
                    // Update local state
                    const photo = state.photos.find(p => p.filename === r.filename);
                    if (photo) {
                        photo.has_gps = true;
                        photo.lat = r.lat;
                        photo.lon = r.lon;
                        photo.status = 'has_gps';
                    }
                    addPhotoMarker(r.filename, r.lat, r.lon, iconMatched);
                }
            }

            state.selectedFiles.clear();
            renderPhotos();
            updateCounts();
            updateAutoGeotagButton();
            hideProgress();

            const failCount = results.length - successCount;
            if (successCount > 0) {
                showToast(`✅ ${successCount}개 사진에 GPS 기록 완료${failCount > 0 ? ` (${failCount}개 실패)` : ''}`, 'success');
            } else {
                showToast(`매칭 가능한 사진이 없습니다`, 'warning');
            }
        } catch (e) {
            showToast('자동 매칭 실패: ' + e.message, 'error');
            hideProgress();
        } finally {
            dom.btnAutoGeotag.disabled = false;
        }
    }

    // ------------------------------------------------------------------
    // Map click-assign mode
    // ------------------------------------------------------------------
    function enterClickAssignMode() {
        state.mapMode = 'click-assign';
        dom.mapInstructions.classList.remove('hidden');
        const count = state.selectedFiles.size;
        dom.instructionsText.textContent = `📍 지도를 클릭하여 ${count}개 사진에 위치를 지정하세요`;
        document.getElementById('map').style.cursor = 'crosshair';
    }

    function cancelMapMode() {
        state.mapMode = null;
        dom.mapInstructions.classList.add('hidden');
        document.getElementById('map').style.cursor = '';
    }

    async function onMapClick(e) {
        if (state.mapMode !== 'click-assign') return;
        if (state.selectedFiles.size === 0) {
            cancelMapMode();
            return;
        }

        const { lat, lng: lon } = e.latlng;
        const filenames = [...state.selectedFiles];

        const confirmed = await showModal(
            '수동 위치 지정',
            `${filenames.length}개 사진을 이 위치에 기록합니다.\n위도: ${lat.toFixed(6)}, 경도: ${lon.toFixed(6)}`,
        );
        if (!confirmed) return;

        cancelMapMode();
        showProgress(30);

        try {
            const items = filenames.map(fn => ({ filename: fn, lat, lon, ele: 0 }));
            const data = await api('POST', '/api/batch-manual-geotag', { items });
            const results = data.results || [];

            let successCount = 0;
            for (const r of results) {
                if (r.success) {
                    successCount++;
                    const photo = state.photos.find(p => p.filename === r.filename);
                    if (photo) {
                        photo.has_gps = true;
                        photo.lat = r.lat;
                        photo.lon = r.lon;
                        photo.status = 'has_gps';
                    }
                    addPhotoMarker(r.filename, r.lat, r.lon, iconManual);
                }
            }

            state.selectedFiles.clear();
            renderPhotos();
            updateCounts();
            updateAutoGeotagButton();
            hideProgress();

            showToast(`✅ ${successCount}개 사진에 수동 GPS 기록 완료`, 'success');
        } catch (e) {
            showToast('GPS 기록 실패: ' + e.message, 'error');
            hideProgress();
        }
    }

    // ------------------------------------------------------------------
    // Map drag-and-drop
    // ------------------------------------------------------------------
    async function onMapDrop(e) {
        e.preventDefault();
        document.getElementById('panel-map').classList.remove('drop-active');

        const filename = e.dataTransfer.getData('text/plain');
        if (!filename) return;

        // Get map coordinates from drop position
        const rect = document.getElementById('map').getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;
        const latlng = map.containerPointToLatLng([x, y]);

        const confirmed = await showModal(
            '위치 지정',
            `"${filename}"을 이 위치에 기록합니다.\n위도: ${latlng.lat.toFixed(6)}, 경도: ${latlng.lng.toFixed(6)}`,
        );
        if (!confirmed) return;

        showProgress(30);

        try {
            const data = await api('POST', '/api/manual-geotag', {
                filename,
                lat: latlng.lat,
                lon: latlng.lng,
                ele: 0,
            });

            if (data.success) {
                const photo = state.photos.find(p => p.filename === filename);
                if (photo) {
                    photo.has_gps = true;
                    photo.lat = latlng.lat;
                    photo.lon = latlng.lng;
                    photo.status = 'has_gps';
                }
                addPhotoMarker(filename, latlng.lat, latlng.lng, iconManual);
                renderPhotos();
                updateCounts();
                showToast(`✅ "${filename}" GPS 기록 완료`, 'success');
            } else {
                showToast('GPS 기록 실패', 'error');
            }
            hideProgress();
        } catch (e) {
            showToast('GPS 기록 실패: ' + e.message, 'error');
            hideProgress();
        }
    }

    // ------------------------------------------------------------------
    // Map markers
    // ------------------------------------------------------------------
    function addPhotoMarker(filename, lat, lon, icon) {
        // Remove existing marker for this file
        if (state.mapMarkers[filename]) {
            map.removeLayer(state.mapMarkers[filename]);
        }

        const marker = L.marker([lat, lon], { icon }).addTo(map);

        const thumbSrc = state.thumbnailCache[filename] || '';
        const popupHtml = `
            <div>
                ${thumbSrc ? `<img class="popup-photo" src="${thumbSrc}">` : ''}
                <div class="popup-filename">${filename}</div>
                <div class="popup-coords">${lat.toFixed(6)}, ${lon.toFixed(6)}</div>
            </div>
        `;
        marker.bindPopup(popupHtml, { maxWidth: 200 });
        state.mapMarkers[filename] = marker;
    }

    // ------------------------------------------------------------------
    // Boot
    // ------------------------------------------------------------------
    document.addEventListener('DOMContentLoaded', init);
})();
