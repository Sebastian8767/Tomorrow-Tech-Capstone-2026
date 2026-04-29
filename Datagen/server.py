import asyncio
import websockets
import json
import csv
import paho.mqtt.publish as publish
import requests
from datetime import datetime
import os

# ── Config ────────────────────────────────────────────────────
SERVER_URL = "https://gbtac-bms-a8eyewead4e5g0fp.canadacentral-01.azurewebsites.net/update"
MQTT_HOST  = "localhost"

DATAGEN_PORT = 9000   # datagen.py connects here
PI_PORT      = 9001   # Raspberry Pi connects here

HOST = "0.0.0.0"      # listen on all interfaces

# ── Shared CSV state ──────────────────────────────────────────
csv_lock     = asyncio.Lock()
all_data     = []
last_written = 0


# ── Generic connection handler ────────────────────────────────
async def handle_connection(websocket, source_label):
    global all_data, last_written

    print(f"[{source_label}] New connection from {websocket.remote_address}")

    write_counter = 0

    try:
        while True:
            response = await websocket.recv()

            # ── Normalise to list of "name,value" strings ─────
            # datagen sends: ["SensorName,value", ...]
            # Pi may send:   {"name": "Temp", "value": 23.5}
            #                or "Temperature,23.5" raw string
            try:
                parsed = json.loads(response)
            except json.JSONDecodeError:
                parsed = [response.strip()]

            if isinstance(parsed, str):
                new_batch = [parsed]
            elif isinstance(parsed, dict):
                new_batch = [f"{parsed['name']},{parsed['value']}"]
            elif isinstance(parsed, list):
                new_batch = parsed
            else:
                print(f"[{source_label}] Unknown format — skipping")
                continue

            # ── Append to shared list ─────────────────────────
            async with csv_lock:
                all_data = all_data + new_batch

            # ── Forward to Azure + MQTT ───────────────────────
            await publishAndForward(new_batch, websocket, source_label)

            # ── Write CSV every 50 batches ────────────────────
            write_counter += 1
            if write_counter % 50 == 0:
                async with csv_lock:
                    last_written = writeCsv(all_data, last_written)
                print(f"[{source_label}] CSV updated ({len(all_data)} total entries)")

    except Exception as e:
        print(f"[{source_label}] Connection closed: {e}")
        async with csv_lock:
            last_written = writeCsv(all_data, last_written)
        print(f"[{source_label}] CSV saved on disconnect.")


# ── Named handlers so we know which source connected ─────────
async def handle_datagen(websocket):
    await handle_connection(websocket, "DATAGEN")

async def handle_pi(websocket):
    await handle_connection(websocket, "PI")


# ── CSV writer ────────────────────────────────────────────────
def writeCsv(inputData, last_written):
    new_entries = inputData[last_written:]
    if not new_entries:
        return last_written

    timestamp = datetime.now().strftime("%Y-%m-%d-%H-%M-%S")
    filepath  = rf"C:\Users\gbtac\Desktop\GBTAC\csv_incoming\trend-log-{timestamp}.csv"

    with open(filepath, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["timestamp", "sensor_tag", "value"])
        for entry in new_entries:
            parts = entry.split(",")
            if len(parts) < 2:
                continue
            sensor_tag = parts[0].strip()
            value      = parts[1].strip()
            ts         = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            writer.writerow([ts, sensor_tag, value])

    return len(inputData)


# ── Forward to Azure Web App + MQTT ──────────────────────────
async def publishAndForward(batchData, websocket, source_label):
    for entry in batchData:
        parts = entry.split(",")
        if len(parts) < 2:
            continue

        sensor_name = parts[0].strip()
        value_str   = parts[1].strip()

        # MQTT
        topic = f"sensors/zoneA/{sensor_name}"
        try:
            publish.single(topic, value_str, hostname=MQTT_HOST)
        except Exception as e:
            print(f"[MQTT ERROR] {e}")

        # Azure Web App
        try:
            val     = float(value_str)
            payload = {"name": sensor_name, "value": val, "instance": 0}

            r               = requests.post(SERVER_URL, json=payload, timeout=1.0)
            server_response = r.json()
            print(f"[{source_label}] OK {sensor_name} = {val}")

            # Only relay ADD_SENSOR commands back to datagen, not Pi
            if source_label == "DATAGEN" and "commands" in server_response:
                for cmd in server_response["commands"]:
                    await websocket.send(json.dumps(cmd))
                    print(f"[GATEWAY] Command sent to datagen: {cmd.get('name')}")

        except Exception:
            pass


# ── Main — two servers running concurrently ───────────────────
async def main():
    datagen_server = await websockets.serve(
        handle_datagen,
        HOST,
        DATAGEN_PORT,
        ping_interval=20,
        ping_timeout=60,
        close_timeout=10
    )

    pi_server = await websockets.serve(
        handle_pi,
        HOST,
        PI_PORT,
        ping_interval=20,
        ping_timeout=60,
        close_timeout=10
    )

    print(f"[CLIENT] Datagen server  → ws://{HOST}:{DATAGEN_PORT}")
    print(f"[CLIENT] Raspberry Pi server → ws://{HOST}:{PI_PORT}")
    print(f"[CLIENT] Forwarding to   → {SERVER_URL}")
    print("[CLIENT] Ready — waiting for connections...")

    await asyncio.gather(
        datagen_server.wait_closed(),
        pi_server.wait_closed()
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[CLIENT] Shutting down.")
