from flask import Flask, request, jsonify, render_template, Response, redirect, url_for, session
import pymssql
from datetime import datetime, timedelta
import io
import csv
import json
import threading
import uuid
import os

app = Flask(__name__)

# ── Session config ────────────────────────────────────────────
app.secret_key                 = os.environ.get("FLASK_SECRET_KEY", "gbtac-secret-2026")
app.permanent_session_lifetime = timedelta(days=7)

# ── Azure SQL credentials from environment variables ──────────
AZURE_SERVER   = os.environ.get("AZURE_SQL_SERVER",   "gbtac-sql.database.windows.net")
AZURE_DATABASE = os.environ.get("AZURE_SQL_DATABASE", "GBTAC-Database")
AZURE_USERNAME = os.environ.get("AZURE_SQL_USERNAME", "gbtacadmin")
AZURE_PASSWORD = os.environ.get("AZURE_SQL_PASSWORD", "your-password-here")

def get_db():
    return pymssql.connect(
        server=AZURE_SERVER,
        user=AZURE_USERNAME,
        password=AZURE_PASSWORD,
        database=AZURE_DATABASE
    )

# ── Command queue ─────────────────────────────────────────────
command_queue      = []
command_queue_lock = threading.Lock()


# ============================================================
# DATABASE INIT + SEED
# ============================================================
def seed_default_sensors():
    default_sensors = [
        {"name": "GBT Total Consumption",                     "unit": "kW",  "min": 250.0, "max": 500.0},
        {"name": "GBT Space heating",                         "unit": "kW",  "min": 100.0, "max": 250.0},
        {"name": "GBT Lighting consumption-TL",               "unit": "kW",  "min": 20.0,  "max": 80.0},
        {"name": "GBT Total Generation",                      "unit": "kW",  "min": 200.0, "max": 500.0},
        {"name": "PV-RooftopSolar_Total",                     "unit": "kW",  "min": 100.0, "max": 300.0},
        {"name": "SaitSolarLab_20000_TL151",                  "unit": "kW",  "min": 50.0,  "max": 150.0},
        {"name": "SLAB_Supply_Water_Temp_POLL",               "unit": "°C",  "min": 35.0,  "max": 45.0},
        {"name": "HRV1_Supply_Temp_POLL",                     "unit": "°C",  "min": 18.0,  "max": 24.0},
        {"name": "HWS_Outside_Temp_POLL",                     "unit": "°C",  "min": -10.0, "max": 15.0},
        {"name": "SLAB_Zn1_Basement_Avg_Space_Temp_AV_POLL",  "unit": "°C",  "min": 19.0,  "max": 23.0},
        {"name": "HRV1_SupFan_Amps_POLL",                     "unit": "A",   "min": 2.0,   "max": 6.0},
        {"name": "HRV2_SupFan_Amps_POLL",                     "unit": "A",   "min": 2.0,   "max": 6.0},
        {"name": "SLAB_P4A_Amps_POLL",                        "unit": "A",   "min": 1.0,   "max": 4.0},
        {"name": "HWS_Post_DHW_Tank_Temp_POLL",               "unit": "°C",  "min": 55.0,  "max": 65.0},
        {"name": "HWS_P1A_Amps_POLL",                         "unit": "A",   "min": 0.5,   "max": 2.5},
        {"name": "DHW_P5_Amps_POLL",                          "unit": "A",   "min": 0.5,   "max": 2.5},
        {"name": "Rain_Water_Level_POLL",                     "unit": "L",   "min": 10.0,  "max": 100.0},
    ]
    conn   = get_db()
    cursor = conn.cursor()
    for s in default_sensors:
        cursor.execute("""
            IF NOT EXISTS (SELECT 1 FROM registered_sensors WHERE name = %s)
            INSERT INTO registered_sensors (name, unit, min_val, max_val, added_at)
            VALUES (%s, %s, %s, %s, %s)
        """, (s["name"], s["name"], s["unit"], s["min"], s["max"],
              datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
    conn.commit()
    conn.close()
    print("[DB] Default sensors seeded.")


def init_sql():
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute("""
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='sensor_history' AND xtype='U')
        CREATE TABLE sensor_history (
            id              INT IDENTITY(1,1) PRIMARY KEY,
            timestamp       NVARCHAR(30),
            sensor_name     NVARCHAR(255),
            value           FLOAT,
            bacnet_instance INT
        )
    """)
    cursor.execute("""
        IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='registered_sensors' AND xtype='U')
        CREATE TABLE registered_sensors (
            id       INT IDENTITY(1,1) PRIMARY KEY,
            name     NVARCHAR(255) UNIQUE,
            unit     NVARCHAR(20),
            min_val  FLOAT,
            max_val  FLOAT,
            added_at NVARCHAR(30)
        )
    """)
    conn.commit()
    conn.close()
    print("[DB] Azure SQL tables verified.")
    seed_default_sensors()


# ── Run init at module level so gunicorn picks it up ─────────
init_sql()


# ============================================================
# ROUTES
# ============================================================

@app.route('/')
def index():
    return redirect(url_for('login'))


@app.route('/guest')
def guest_login():
    if not session.get('guest_id'):
        session['guest_id']  = str(uuid.uuid4())[:8].upper()
        session['logged_in'] = True
        session['role']      = 'guest'
        session.permanent    = True
    return redirect(url_for('home'))


@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form['username'] == 'admin' and request.form['password'] == 'password123':
            session['logged_in'] = True
            session['role']      = 'admin'
            session['name']      = 'System Admin'
            session.permanent    = True
            return redirect(url_for('home'))
        return render_template('login.html', error="Invalid credentials")
    return render_template('login.html')


@app.route('/logout')
def logout():
    session.clear()
    return render_template('logout.html')


@app.route('/home')
def home():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    access_denied = session.pop('access_denied', False)
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT TOP 1000 id, timestamp, sensor_name, value, bacnet_instance FROM sensor_history ORDER BY id DESC')
    sensor_data = cursor.fetchall()
    conn.close()
    return render_template('home.html', data=sensor_data, access_denied=access_denied)


@app.route('/about')
def about():
    return render_template('about.html')


@app.route('/admin', methods=['GET', 'POST'])
def admin():
    if session.get('role') == 'guest':
        session['access_denied'] = True
        return redirect(url_for('home'))

    if request.method == 'POST':
        sensor_name = request.form.get('sensor_name')
        unit        = request.form.get('unit')
        min_val     = request.form.get('min_val')
        max_val     = request.form.get('max_val')

        if not all([sensor_name, unit, min_val, max_val]):
            return jsonify({"status": "error", "message": "All fields are required."}), 400

        try:
            min_val = float(min_val)
            max_val = float(max_val)
        except ValueError:
            return jsonify({"status": "error", "message": "Min and Max must be numbers."}), 400

        if min_val >= max_val:
            return jsonify({"status": "error", "message": "Min must be less than Max."}), 400

        try:
            conn   = get_db()
            cursor = conn.cursor()
            cursor.execute("""
                IF NOT EXISTS (SELECT 1 FROM registered_sensors WHERE name = %s)
                INSERT INTO registered_sensors (name, unit, min_val, max_val, added_at)
                VALUES (%s, %s, %s, %s, %s)
            """, (sensor_name, sensor_name, unit, min_val, max_val,
                  datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
            conn.commit()
            conn.close()
        except Exception as e:
            return jsonify({"status": "error", "message": f"DB error: {str(e)}"}), 500

        command = {
            "command": "ADD_SENSOR",
            "name":    sensor_name,
            "unit":    unit,
            "min":     min_val,
            "max":     max_val
        }
        with command_queue_lock:
            command_queue.append(command)

        return jsonify({
            "status":  "success",
            "message": f"Sensor '{sensor_name}' registered and queued for live injection."
        }), 200

    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT id, name, unit, min_val, max_val, added_at FROM registered_sensors ORDER BY added_at DESC')
    sensors = cursor.fetchall()
    cursor.execute('''
        SELECT DISTINCT sensor_name FROM sensor_history
        WHERE sensor_name NOT IN (SELECT name FROM registered_sensors)
        ORDER BY sensor_name ASC
    ''')
    unregistered = [row[0] for row in cursor.fetchall()]
    conn.close()
    return render_template('admin.html', sensors=sensors, unregistered=unregistered)


@app.route('/delete_sensor/<sensor_name>', methods=['POST'])
def delete_sensor(sensor_name):
    if session.get('role') == 'guest':
        session['access_denied'] = True
        return redirect(url_for('home'))
    try:
        conn   = get_db()
        cursor = conn.cursor()
        cursor.execute("DELETE FROM registered_sensors WHERE name = %s", (sensor_name,))
        cursor.execute("DELETE FROM sensor_history WHERE sensor_name = %s", (sensor_name,))
        conn.commit()
        conn.close()
        return jsonify({"status": "success", "message": f"Sensor '{sensor_name}' deleted."}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route('/superuser')
def superuser():
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT id, name, unit, min_val, max_val, added_at FROM registered_sensors ORDER BY added_at DESC')
    sensors = cursor.fetchall()
    conn.close()
    return render_template('superuser.html', sensors=sensors)


@app.route('/sensor_browser')
def sensor_browser():
    return render_template('sensor_browser.html')


@app.route('/historical_data')
def historical_data():
    return render_template('historical_data.html')


@app.route('/user_admin_settings')
def user_admin_settings():
    return render_template('user_admin_settings.html')

@app.route('/csv_dashboard')
def csv_dashboard():
    return render_template('bms_dashboard_with_csv.html')

@app.route('/test_admin')
def test_admin_view():
    if session.get('role') == 'guest':
        session['access_denied'] = True
    return redirect(url_for('home'))
    


# ============================================================
# API ROUTES
# ============================================================

@app.route('/update', methods=['POST'])
def handle_post():
    data = request.json
    try:
        conn   = get_db()
        cursor = conn.cursor()
        cursor.execute(
            "INSERT INTO sensor_history (timestamp, sensor_name, value, bacnet_instance) VALUES (%s, %s, %s, %s)",
            (datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
             data['name'], data['value'], data['instance'])
        )
        conn.commit()
        conn.close()
        print(f"[SQL SUCCESS] Recorded {data['name']} = {data['value']}")

        pending_commands = []
        with command_queue_lock:
            if command_queue:
                pending_commands = list(command_queue)
                command_queue.clear()

        return jsonify({"status": "success", "commands": pending_commands}), 200

    except Exception as e:
        print(f"[SQL ERROR] {e}")
        return jsonify({"status": "error", "message": str(e)}), 500


@app.route('/api/data')
def get_live_data():
    limit  = request.args.get('limit', default=20, type=int)
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute(f'SELECT TOP {limit * 10} id, timestamp, sensor_name, value, bacnet_instance FROM sensor_history ORDER BY id DESC')
    rows = cursor.fetchall()
    conn.close()
    return jsonify([{
        "id":        row[0],
        "timestamp": row[1],
        "name":      row[2],
        "value":     row[3]
    } for row in rows])


@app.route('/api/registered_sensors')
def get_registered_sensors():
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT name, unit, min_val, max_val FROM registered_sensors')
    rows = cursor.fetchall()
    conn.close()
    return jsonify([{
        "name": row[0],
        "unit": row[1],
        "min":  row[2],
        "max":  row[3]
    } for row in rows])


@app.route('/api/historical')
def get_historical():
    start   = request.args.get('start', '')
    end     = request.args.get('end', '')
    sensors = request.args.get('sensors', '')
    try:
        conn   = get_db()
        cursor = conn.cursor()
        if sensors:
            sensor_list  = [s.strip() for s in sensors.split(',')]
            placeholders = ','.join(['%s' for _ in sensor_list])
            if start and end:
                cursor.execute(f"""
                    SELECT TOP 5000 timestamp, sensor_name, value
                    FROM sensor_history
                    WHERE sensor_name IN ({placeholders})
                    AND timestamp >= %s AND timestamp <= %s
                    ORDER BY timestamp ASC
                """, (*sensor_list, start, end))
            else:
                cursor.execute(f"""
                    SELECT TOP 5000 timestamp, sensor_name, value
                    FROM sensor_history
                    WHERE sensor_name IN ({placeholders})
                    ORDER BY timestamp ASC
                """, sensor_list)
        else:
            if start and end:
                cursor.execute("""
                    SELECT TOP 5000 timestamp, sensor_name, value
                    FROM sensor_history
                    WHERE timestamp >= %s AND timestamp <= %s
                    ORDER BY timestamp ASC
                """, (start, end))
            else:
                cursor.execute("""
                    SELECT TOP 5000 timestamp, sensor_name, value
                    FROM sensor_history ORDER BY timestamp DESC
                """)
        rows = cursor.fetchall()
        conn.close()
        return jsonify([{"timestamp": r[0], "sensor_name": r[1], "value": r[2]} for r in rows])
    except Exception as e:
        print(f"[HISTORICAL ERROR] {e}")
        return jsonify({"error": str(e)}), 500


@app.route('/api/sensor_names')
def get_sensor_names():
    try:
        conn   = get_db()
        cursor = conn.cursor()
        cursor.execute("SELECT DISTINCT sensor_name FROM sensor_history ORDER BY sensor_name ASC")
        rows = cursor.fetchall()
        conn.close()
        return jsonify([row[0] for row in rows])
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route('/export_csv')
def export_csv():
    headers = [
        'ts', 'GBT Total Consumption', 'GBT Total Generation',
        'GBT Space heating', 'GBT Lighting consumption-TL',
        'PV-RooftopSolar_Total', 'SaitSolarLab_20000_TL151',
        'SLAB_Supply_Water_Temp_POLL', 'HRV1_Supply_Temp_POLL',
        'HWS_Outside_Temp_POLL', 'SLAB_Zn1_Basement_Avg_Space_Temp_AV_POLL',
        'HRV1_SupFan_Amps_POLL', 'HRV2_SupFan_Amps_POLL', 'SLAB_P4A_Amps_POLL',
        'HWS_Post_DHW_Tank_Temp_POLL', 'HWS_P1A_Amps_POLL',
        'DHW_P5_Amps_POLL', 'Rain_Water_Level_POLL'
    ]
    conn   = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT timestamp, sensor_name, value FROM sensor_history ORDER BY timestamp ASC")
    rows = cursor.fetchall()
    conn.close()

    data_by_ts = {}
    for ts, name, val in rows:
        if ts not in data_by_ts:
            data_by_ts[ts] = {}
        data_by_ts[ts][name] = val

    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(headers)
    for ts in sorted(data_by_ts.keys()):
        row_dict = data_by_ts[ts]
        row = [ts] + [row_dict.get(h, '') for h in headers[1:]]
        writer.writerow(row)

    return Response(
        output.getvalue(),
        mimetype="text/csv",
        headers={"Content-disposition": "attachment; filename=BMS_Full_Report.csv"}
    )


if __name__ == '__main__':
    print("BMS Server running on http://0.0.0.0:5000")
    app.run(host='0.0.0.0', port=5000, debug=False)