import random
import time
import threading
from datetime import datetime
import asyncio
import websockets
import json
import requests

finalData = []
dataLock = threading.Lock()

# The BMS server address
VM2_SERVER_IP = "gbtac-bms-a8eyewead4e5g0fp.canadacentral-01.azurewebsites.net"       # ← your local machine's IP from ipconfig
BMS_URL = f"https://{VM2_SERVER_IP}/update"

# ── Where client.py (now the server) is listening ─────────────
# CLIENT_IP  = "localhost"        # ← Update to your Azure VM / client.py IP
# CLIENT_WS  = f"ws://{CLIENT_IP}:9000"
CLIENT2_IP = "localhost"
CLIENT2_SW = f"ws://{CLIENT2_IP}:9001"


class Sensor:
    def __init__(self, name, data, interval, minVal, maxVal, dataunit=None):
        self.name = name
        self.data = data
        self.interval = interval
        self.minVal = minVal
        self.maxVal = maxVal
        self.dataunit = dataunit
        self.running = False

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._generate)
        self.thread.start()
        print("Sensor thread " + self.name + " is now running successfully")

    def stop(self):
        self.running = False
        if self.thread:
            print("Sensor thread " + self.name + " has successfully stopped.")

    def _generate(self):
        while self.running:
            data = formatData(self)
            with dataLock:
                finalData.append(data)
            time.sleep(self.interval)


def generateData(minVal, maxVal):
    value = random.uniform(minVal, maxVal)
    return value


def startSensors(sensorsList):
    for sens in sensorsList:
        try:
            sens.start()
        except:
            print("Error starting sensor.")


def stopSensors(sensorsList):
    for sens in sensorsList:
        sens.stop()


def formatData(sensor):
    name = sensor.name
    running = sensor.running
    minVal = sensor.minVal
    maxVal = sensor.maxVal

    div = f"=" * 35
    print(div)
    print(f"Sensor Name: {name}")

    while running:
        dataSample = generateData(minVal, maxVal)
        data = (name + "," + str(dataSample))
        print(data)
        return data


def inject_sensor(name, unit, min_val, max_val, sensor_list):
    print(f"[INJECT] Creating new sensor: {name} ({min_val}-{max_val} {unit})")

    for existing in sensor_list:
        if existing.name == name:
            print(f"[INJECT] Sensor '{name}' already exists. Skipping.")
            return

    interval = random.randint(1, 4)
    new_sensor = Sensor(name, [], interval, min_val, max_val, dataunit=unit)
    new_sensor.start()
    sensor_list.append(new_sensor)
    print(f"[INJECT] Sensor '{name}' is now live and generating data.")


def load_registered_sensors(sensor_list):
    print("[STARTUP] Fetching registered sensors from BMS server...")
    try:
        r = requests.get(f"{BMS_URL}/api/registered_sensors", timeout=5)
        sensors = r.json()
        if not sensors:
            print("[STARTUP] No registered sensors found in DB.")
            return
        for s in sensors:
            inject_sensor(s["name"], s["unit"], s["min"], s["max"], sensor_list)
        print(f"[STARTUP] Loaded {len(sensors)} registered sensor(s) from DB.")
    except Exception as e:
        print(f"[STARTUP] Could not reach BMS server to load sensors: {e}")
        print("[STARTUP] Continuing with default sensors only.")


def createSensors(sensorCount, minVal, maxVal):
    arr = []
    metrics_config = [
        #Energy Consumption (kW)
        {"name": "GBT Total Consumption",                     "unit": "kW",  "min": 250.0, "max": 500.0},
        {"name": "GBT Space heating",                         "unit": "kW",  "min": 100.0, "max": 250.0},
        {"name": "GBT Lighting consumption-TL",               "unit": "kW",  "min": 20.0,  "max": 80.0},
        #Energy Generation (kW)
        {"name": "GBT Total Generation",                      "unit": "kW",  "min": 200.0, "max": 500.0},
        {"name": "PV-RooftopSolar_Total",                     "unit": "kW",  "min": 100.0, "max": 300.0},
        {"name": "SaitSolarLab_20000_TL151",                  "unit": "kW",  "min": 50.0,  "max": 150.0},
        #Temperature Sensors (°C)
        {"name": "SLAB_Supply_Water_Temp_POLL",               "unit": "°C",  "min": 35.0,  "max": 45.0},
        {"name": "HRV1_Supply_Temp_POLL",                     "unit": "°C",  "min": 18.0,  "max": 24.0},
        {"name": "HWS_Outside_Temp_POLL",                     "unit": "°C",  "min": -10.0, "max": 15.0},
        {"name": "SLAB_Zn1_Basement_Avg_Space_Temp_AV_POLL",  "unit": "°C",  "min": 19.0,  "max": 23.0},
        # HVAC Systems (Amps)
        {"name": "HRV1_SupFan_Amps_POLL",                     "unit": "A",   "min": 2.0,   "max": 6.0},
        {"name": "HRV2_SupFan_Amps_POLL",                     "unit": "A",   "min": 2.0,   "max": 6.0},
        {"name": "SLAB_P4A_Amps_POLL",                        "unit": "A",   "min": 1.0,   "max": 4.0},
        # Hot Water Systems (°C and Amps)
        {"name": "HWS_Post_DHW_Tank_Temp_POLL",               "unit": "°C",  "min": 55.0,  "max": 65.0},
        {"name": "HWS_P1A_Amps_POLL",                         "unit": "A",   "min": 0.5,   "max": 2.5},
        {"name": "DHW_P5_Amps_POLL",                          "unit": "A",   "min": 0.5,   "max": 2.5},
        #Water Levels (L)
        {"name": "Rain_Water_Level_POLL",                     "unit": "L", "min": 10.0, "max": 100.0},
    ]

    randInterval = random.randint(1, 4)
    for sensor in metrics_config:
        tempSens = Sensor(
            sensor["name"],
            [],
            randInterval,
            sensor["min"],
            sensor["max"]
        )
        arr.append(tempSens)

    return arr


async def sendData(websocket, sensor_list):
    """
    Producer: sends accumulated sensor data to client.py every 2 seconds.
    Consumer: listens for ADD_SENSOR commands sent back from client.py.
    """
    async def producer():
        while True:
            with dataLock:
                if finalData:
                    await websocket.send(json.dumps(finalData))
                    finalData.clear()
            await asyncio.sleep(2)

    async def consumer():
        async for message in websocket:
            try:
                cmd_data = json.loads(message)
                if cmd_data.get("command") == "ADD_SENSOR":
                    inject_sensor(
                        cmd_data["name"],
                        cmd_data["unit"],
                        cmd_data["min"],
                        cmd_data["max"],
                        sensor_list
                    )
                    print(f"[DATAGEN] ADD_SENSOR received for '{cmd_data['name']}'")
            except Exception as e:
                print(f"[DATAGEN] Error processing command: {e}")

    await asyncio.gather(producer(), consumer())


async def main():
    sensorsList = []

    solarSensors = createSensors(20, 50.0, 150.0)
    sensorsList.extend(solarSensors)
    startSensors(sensorsList)

    load_registered_sensors(sensorsList)

    # ── Outer retry loop — reconnects if client.py drops ──────
    while True:
        try:
            print(f"[DATAGEN] Connecting to client at {CLIENT2_SW}...")
            async with websockets.connect(
                CLIENT2_SW,
                ping_interval=20,
                ping_timeout=60,
                close_timeout=10
            ) as websocket:
                print("[DATAGEN] Connected successfully.")
                await sendData(websocket, sensorsList)

        except Exception as e:
            print(f"[DATAGEN] Connection closed: {e}")
            print("[DATAGEN] Reconnecting in 5 seconds...")
            await asyncio.sleep(5)


try:
    asyncio.run(main())
except KeyboardInterrupt:
    print("Server Stopping")
