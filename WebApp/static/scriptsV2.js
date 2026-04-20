// ============================================================
// scriptsV2.js — GBTAC BMS Live Dashboard
// ============================================================

// --- 1. GLOBAL VARIABLES ---
let energyChart        = null;
let historyChart       = null;
let currentHistoryLimit = 50;
let sensorHealthMap    = {};
let isPaused           = false;
let liveChartSensorId  = null;   // tracks which sensor the history chart is showing

// ── Known sensors from datagen.py (used as CSV column base) ──
// These are the 16 hardcoded sensors. Any sensor added via
// /admin will be fetched dynamically and appended at export time.
const BASE_SENSOR_HEADERS = [
    'ts',
    // Energy Consumption
    'GBT Total Consumption',
    'GBT Space heating',
    'GBT Lighting consumption-TL',
    // Energy Generation
    'GBT Total Generation',
    'PV-RooftopSolar_Total',
    'SaitSolarLab_20000_TL151',
    // Temperature
    'SLAB_Supply_Water_Temp_POLL',
    'HRV1_Supply_Temp_POLL',
    'HWS_Outside_Temp_POLL',
    'SLAB_Zn1_Basement_Avg_Space_Temp_AV_POLL',
    // HVAC
    'HRV1_SupFan_Amps_POLL',
    'HRV2_SupFan_Amps_POLL',
    'SLAB_P4A_Amps_POLL',
    // Hot Water
    'HWS_Post_DHW_Tank_Temp_POLL',
    'HWS_P1A_Amps_POLL',
    'DHW_P5_Amps_POLL'
];


// --- 2. PAUSE TOGGLE ---
function togglePause() {
    isPaused = !isPaused;
    const btn        = document.getElementById('pauseBtn');
    const dot        = document.querySelector('.status-dot');
    const statusText = document.querySelector('.status-text');

    if (isPaused) {
        btn.textContent         = 'Resume';
        btn.style.borderColor   = 'var(--accent-primary)';
        btn.style.color         = 'var(--accent-primary)';
        if (dot)        dot.style.animationPlayState = 'paused';
        if (statusText) statusText.textContent       = 'Feed Paused';
    } else {
        btn.textContent         = 'Pause';
        btn.style.borderColor   = 'var(--accent-warning)';
        btn.style.color         = 'var(--accent-warning)';
        if (dot)        dot.style.animationPlayState = 'running';
        if (statusText) statusText.textContent       = 'System Online';
    }
}


// --- 3. CHART LIMIT ---
function setChartLimit(num) {
    currentHistoryLimit = num;
    if (historyChart) {
        historyChart.data.labels           = [];
        historyChart.data.datasets[0].data = [];
        historyChart.update();
    }
    lookupSensor();
}


// --- 4. INITIALIZE CHARTS ON DOM READY ---
document.addEventListener('DOMContentLoaded', () => {
    const ctx = document.getElementById('energyChart').getContext('2d');
    energyChart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: INITIAL_CHART_LABELS,
            datasets: [
                {
                    label:           'Consumption (kW)',
                    data:            INITIAL_CONSUMPTION,
                    borderColor:     '#ff3366',
                    backgroundColor: 'rgba(255, 51, 102, 0.1)',
                    borderWidth:     2,
                    tension:         0.3,
                    fill:            false,
                    pointRadius:     0,
                    pointHoverRadius: 6
                },
                {
                    label:           'Generation (kW)',
                    data:            INITIAL_GENERATION,
                    borderColor:     '#00ff88',
                    backgroundColor: 'rgba(0, 255, 136, 0.1)',
                    borderWidth:     2,
                    tension:         0.4,
                    fill:            false,
                    pointRadius:     0,
                    pointHoverRadius: 6
                }
            ]
        },
        options: {
            animation:          false,
            responsive:         true,
            maintainAspectRatio: false,
            plugins: { legend: { labels: { color: '#fff' } } },
            scales: {
                y: { grid: { color: '#333' }, ticks: { color: '#888' } },
                x: { grid: { color: '#333' }, ticks: { color: '#888' } }
            }
        }
    });

    // Start live updates every second
    setInterval(updateDashboard, 1000);
    // Start health checks every 3 seconds
    setInterval(checkSensorHealth, 3000);
});


// --- 5. LIVE UPDATE LOGIC ---
async function updateDashboard() {
    if (isPaused) return;
    try {
        const response = await fetch('/api/data?limit=100');
        const newData  = await response.json();
        if (!newData || newData.length === 0) return;

        newData.forEach(item => {
            sensorHealthMap[item.name] = Date.now();
            const safeName = item.name.replace(/[\s\-\.]/g, '_');

            // Update big metric cards
            const bigCard = document.getElementById(`val-${safeName}`);
            if (bigCard) {
                bigCard.innerHTML = `${item.value.toFixed(1)} <span class="metric-unit">kW</span>`;
            }

            // Update summary stats
            const summaryEl = document.getElementById(`sum-${safeName}`);
            if (summaryEl) {
                summaryEl.innerText = item.value.toFixed(1);
            }

            // Update sidebar
            updateSidebarSensor(item);
        });

        // Update main energy chart
        if (energyChart) {
            const consumption = newData.filter(d => d.name === 'GBT Total Consumption').reverse();
            const generation  = newData.filter(d => d.name === 'GBT Total Generation').reverse();

            if (consumption.length > 0) {
                energyChart.data.labels           = consumption.map(d => d.timestamp.split(' ')[1]);
                energyChart.data.datasets[0].data = consumption.map(d => d.value);
                energyChart.data.datasets[1].data = generation.map(d => d.value);
                energyChart.update('none');
            }
        }

        // ── Live history chart — updates automatically if a sensor is selected ──
        if (liveChartSensorId && historyChart) {
            let sensorHistory = newData.filter(d => d.name === liveChartSensorId).reverse();
            if (sensorHistory.length > 0) {
                if (sensorHistory.length > currentHistoryLimit) {
                    sensorHistory = sensorHistory.slice(-currentHistoryLimit);
                }

                const latest = sensorHistory[sensorHistory.length - 1];

                // Determine unit
                let unit = 'kW';
                if (liveChartSensorId.includes('Temp')  || liveChartSensorId.includes('Sensor')) unit = '°C';
                if (liveChartSensorId.includes('Amps')  || liveChartSensorId.includes('P1A'))    unit = 'A';
                if (liveChartSensorId.includes('Level'))                                          unit = '%';

                // Update the current value display
                document.getElementById('searchedSensorValue').innerHTML =
                    `${latest.value.toFixed(1)} <span class="metric-unit">${unit}</span>`;

                // Push new point onto the chart — slide window forward
                historyChart.data.labels           = sensorHistory.map(d => d.timestamp.split(' ')[1]);
                historyChart.data.datasets[0].data = sensorHistory.map(d => d.value);
                historyChart.update('none');
            }
        }
    } catch (error) {
        console.error("Update failed:", error);
    }
}


// --- 6. SIDEBAR SENSOR UPDATE ---
function updateSidebarSensor(item) {
    const list = document.getElementById('live-sensor-list');
    if (!list) return;

    const summary_metrics = [
        'GBT Total Consumption',
        'GBT Total Generation',
        'GBT Space heating',
        'GBT Lighting consumption-TL'
    ];
    if (summary_metrics.includes(item.name)) return;

    let sensorItem = document.querySelector(`[data-sensor-id="${item.name}"]`);

    // Determine unit
    let unit = 'kW';
    if (item.name.includes('Temp')   || item.name.includes('Sensor')) unit = '°C';
    if (item.name.includes('Amps')   || item.name.includes('P1A'))    unit = 'A';
    if (item.name.includes('Level'))                                   unit = '%';

    if (!sensorItem) {
        const displayName = item.name.replace('_POLL', '').replace(/_/g, ' ');

        // BUG FIX: malformed <div> tag was missing closing bracket and sensor-id span
        list.insertAdjacentHTML('beforeend', `
            <div class="sensor-item" data-sensor-id="${item.name}" onclick="quickLookup('${item.name}')" style="cursor: pointer;">
                <div class="sensor-info">
                    <div class="sensor-name">${displayName}</div>
                    <div class="sensor-id">${item.name} • <span style="color: var(--accent-primary);">Active</span></div>
                </div>
                <div class="sensor-value">${item.value.toFixed(1)}${unit}</div>
            </div>
        `);
    } else {
        sensorItem.querySelector('.sensor-value').innerText = `${item.value.toFixed(1)}${unit}`;
    }

    // Apply active filter to new item
    const searchTerm  = document.getElementById('sidebarFilterInput').value.toLowerCase();
    const newItem     = document.querySelector(`[data-sensor-id="${item.name}"]`);
    if (newItem && searchTerm && !item.name.toLowerCase().includes(searchTerm)) {
        newItem.style.display = 'none';
    }
}


// --- 7. SENSOR HISTORY LOOKUP ---
async function lookupSensor() {
    const sensorId = document.getElementById('sensorSearchInput').value;
    if (!sensorId) return;

    // Store selected sensor so updateDashboard() can keep refreshing it
    liveChartSensorId = sensorId;

    try {
        const response = await fetch(`/api/data?limit=200`);
        const allData  = await response.json();

        let sensorHistory = allData.filter(d => d.name === sensorId).reverse();
        if (sensorHistory.length === 0) return;

        if (sensorHistory.length > currentHistoryLimit) {
            sensorHistory = sensorHistory.slice(-currentHistoryLimit);
        }

        const latest = sensorHistory[sensorHistory.length - 1];

        let unit = 'kW';
        if (sensorId.includes('Temp')  || sensorId.includes('Sensor')) unit = '°C';
        if (sensorId.includes('Amps')  || sensorId.includes('P1A'))    unit = 'A';
        if (sensorId.includes('Level'))                                  unit = '%';

        document.getElementById('searchedSensorName').innerText  = sensorId.replace(/_/g, ' ');
        document.getElementById('searchedSensorValue').innerHTML =
            `${latest.value.toFixed(1)} <span class="metric-unit">${unit}</span>`;

        // Show LIVE badge next to sensor name
        const nameEl = document.getElementById('searchedSensorName');
        if (nameEl && !nameEl.querySelector('.live-badge')) {
            const badge = document.createElement('span');
            badge.className   = 'live-badge';
            badge.textContent = '● LIVE';
            badge.style.cssText = `
                margin-left: 10px;
                font-size: 10px;
                font-weight: 700;
                font-family: 'JetBrains Mono', monospace;
                color: var(--accent-primary);
                background: rgba(0, 255, 136, 0.12);
                border: 1px solid var(--accent-primary);
                border-radius: 4px;
                padding: 2px 6px;
                letter-spacing: 1px;
                animation: pulse 2s ease-in-out infinite;
                vertical-align: middle;
            `;
            nameEl.appendChild(badge);
        }

        const ctx    = document.getElementById('sensorHistoryChart').getContext('2d');
        const labels = sensorHistory.map(d => d.timestamp.split(' ')[1]);
        const values = sensorHistory.map(d => d.value);

        if (historyChart) {
            historyChart.data.labels           = labels;
            historyChart.data.datasets[0].data = values;
            historyChart.update('none');
        } else {
            historyChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels:   labels,
                    datasets: [{
                        label:           'Value History',
                        data:            values,
                        borderColor:     '#00d4ff',
                        backgroundColor: 'rgba(0, 212, 255, 0.1)',
                        borderWidth:     2,
                        pointRadius:     2,
                        fill:            true,
                        tension:         0.3
                    }]
                },
                options: {
                    responsive:          true,
                    maintainAspectRatio: false,
                    animation:           false,
                    plugins: { legend: { display: false } },
                    scales: {
                        x: { ticks: { color: '#888', maxRotation: 0 } },
                        y: { ticks: { color: '#888' } }
                    }
                }
            });
        }
    } catch (err) {
        console.error("Search failed:", err);
    }
}

// Helper for sidebar click
function quickLookup(id) {
    document.getElementById('sensorSearchInput').value = id;
    lookupSensor();
}


// --- 8. EXPORT TO CSV ---
// Dynamically fetches registered sensors from /api/registered_sensors
// so any sensor added via the admin panel is automatically included.
async function exportToCSV() {
    try {
        // Fetch sensor data and registered sensors in parallel
        const [dataResponse, registeredResponse] = await Promise.all([
            fetch('/api/data?limit=500'),
            fetch('/api/registered_sensors')
        ]);

        const allData          = await dataResponse.json();
        const registeredSensors = await registeredResponse.json();

        if (!allData || allData.length === 0) {
            alert("No data to export yet.");
            return;
        }

        // Build headers: base sensors + any dynamically added sensors
        // Filter out duplicates in case a registered sensor matches a base one
        const registeredNames  = registeredSensors.map(s => s.name);
        const extraSensors     = registeredNames.filter(name => !BASE_SENSOR_HEADERS.includes(name));
        const headers          = [...BASE_SENSOR_HEADERS, ...extraSensors];

        // Group rows by 5-second time buckets
        const rowsByTime = {};

        allData.forEach(item => {
            const date = new Date(item.timestamp);
            date.setSeconds(Math.floor(date.getSeconds() / 5) * 5);
            date.setMilliseconds(0);
            const timeKey = date.toISOString().replace('T', ' ').split('.')[0];

            if (!rowsByTime[timeKey]) rowsByTime[timeKey] = { ts: timeKey };

            // Only write columns that exist in our headers
            if (headers.includes(item.name)) {
                rowsByTime[timeKey][item.name] = item.value;
            }
        });

        // Build CSV string
        let csvContent = headers.join(',') + '\n';
        Object.keys(rowsByTime).sort().forEach(time => {
            const row = headers.map(h => {
                if (h === 'ts') return rowsByTime[time].ts;
                return rowsByTime[time][h] !== undefined ? rowsByTime[time][h] : '';
            });
            csvContent += row.join(',') + '\n';
        });

        // Trigger download with timestamped filename
        const now       = new Date();
        const timestamp = `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}_${String(now.getHours()).padStart(2,'0')}-${String(now.getMinutes()).padStart(2,'0')}`;

        const blob = new Blob([csvContent], { type: 'text/csv' });
        const url  = window.URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href     = url;
        a.download = `BMS_Export_${timestamp}.csv`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        window.URL.revokeObjectURL(url);   // BUG FIX: free memory after download

    } catch (err) {
        console.error("Export error:", err);
        alert("Export failed. Check console for details.");
    }
}


// --- 9. SIDEBAR FILTER ---
document.getElementById('sidebarFilterInput').addEventListener('input', function(e) {
    const searchTerm  = e.target.value.toLowerCase();
    const sensorItems = document.querySelectorAll('.sensor-item');

    sensorItems.forEach(item => {
        const sensorName = item.querySelector('.sensor-name').innerText.toLowerCase();
        const sensorId   = item.getAttribute('data-sensor-id').toLowerCase();

        item.style.display = (sensorName.includes(searchTerm) || sensorId.includes(searchTerm))
            ? 'flex'
            : 'none';
    });
});


// --- 10. SENSOR HEALTH CHECK ---
function checkSensorHealth() {
    const now     = Date.now();
    const timeout = 5000;

    Object.keys(sensorHealthMap).forEach(sensorId => {
        const lastSeen   = sensorHealthMap[sensorId];
        const sensorItem = document.querySelector(`[data-sensor-id="${sensorId}"]`);

        if (sensorItem) {
            // BUG FIX: was looking for .sensor-id which didn't exist in the old HTML template
            const statusEl = sensorItem.querySelector('.sensor-id');
            if (!statusEl) return;

            if (now - lastSeen > timeout) {
                statusEl.innerHTML    = `${sensorId} • <span style="color: #ff3366; font-weight: bold;">OFFLINE</span>`;
                sensorItem.style.opacity = '0.6';
            } else {
                statusEl.innerHTML    = `${sensorId} • <span style="color: var(--accent-primary);">Active</span>`;
                sensorItem.style.opacity = '1.0';
            }
        }
    });
}