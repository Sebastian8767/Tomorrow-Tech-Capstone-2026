import logging
import os
import time
from io import BytesIO
from urllib.parse import urlparse

import azure.functions as func
import pandas as pd
import pyodbc
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.core.exceptions import ResourceNotFoundError

app = func.FunctionApp()


def move_blob(blob_service, container_name, source_blob_name, target_folder):
    target_blob_name = source_blob_name.replace("incoming/", f"{target_folder}/", 1)

    source_blob_client = blob_service.get_blob_client(
        container=container_name,
        blob=source_blob_name
    )
    target_blob_client = blob_service.get_blob_client(
        container=container_name,
        blob=target_blob_name
    )

    target_blob_client.start_copy_from_url(source_blob_client.url)
    logging.info(f"Started copy to {target_folder}: {target_blob_name}")

    for _ in range(10):
        props = target_blob_client.get_blob_properties()
        if props.copy.status == "success":
            logging.info(f"Copy completed: {target_blob_name}")
            break
        time.sleep(1)
    else:
        raise Exception(f"Blob copy to {target_folder} folder did not complete in time.")

    source_blob_client.delete_blob()
    logging.info(f"Deleted original blob from incoming: {source_blob_name}")


@app.function_name(name="CsvBlobTrigger")
@app.event_grid_trigger(arg_name="event")
def csv_blob_trigger(event: func.EventGridEvent):
    blob_service = None
    container_name = None
    blob_name = None

    try:
        logging.info("Event Grid trigger fired")

        data = event.get_json()
        blob_url = data["url"]
        logging.info(f"New blob uploaded: {blob_url}")

        if "/sensor-csv/incoming/" not in blob_url or not blob_url.lower().endswith(".csv"):
            logging.info("Skipping non-target blob")
            return

        # FIX: Use DefaultAzureCredential with the blob service URI injected by TT_FunctionApp.bicep.
        # The Flex Consumption plan sets AzureWebJobsStorage__accountName for the runtime and
        # AzureWebJobsStorage__blobServiceUri for application code.
        # This avoids storing a storage account key and works with the managed-identity role
        # assignment (Storage Blob Data Contributor) already granted by the bicep template.
        blob_service_uri = os.environ["AzureWebJobsStorage__blobServiceUri"]
        credential = DefaultAzureCredential()
        blob_service = BlobServiceClient(account_url=blob_service_uri, credential=credential)

        parsed = urlparse(blob_url)
        path_parts = parsed.path.lstrip("/").split("/", 1)
        container_name = path_parts[0]
        blob_name = path_parts[1]

        blob_client = blob_service.get_blob_client(container=container_name, blob=blob_name)

        csv_data = None

        # Retry in case Event Grid fires before blob is fully available
        for attempt in range(3):
            try:
                csv_data = blob_client.download_blob().readall()
                break
            except ResourceNotFoundError:
                if attempt < 2:
                    logging.info("Blob not ready yet, retrying...")
                    time.sleep(2)
                else:
                    logging.warning(f"Blob not found after retries, skipping event: {blob_name}")
                    return

        if csv_data is None:
            logging.warning(f"No blob content found, skipping event: {blob_name}")
            return

        df = pd.read_csv(BytesIO(csv_data))

        logging.info(f"Rows detected: {len(df)}")
        logging.info(f"CSV columns: {list(df.columns)}")

        conn = pyodbc.connect(os.environ["SqlConnectionString"])
        logging.info("SQL connection opened")

        cursor = conn.cursor()

        for _, row in df.iterrows():
            if {"timestamp", "sensor_tag", "value"}.issubset(df.columns):
                source_system = "GBTAC_BMS"
                source_tag = row["sensor_tag"]
                observed_at = row["timestamp"]
                value_raw = str(row["value"])

            elif {"source_system", "source_tag", "observed_at", "value_raw"}.issubset(df.columns):
                source_system = row["source_system"]
                source_tag = row["source_tag"]
                observed_at = row["observed_at"]
                value_raw = str(row["value_raw"])

            else:
                raise Exception(f"Unsupported CSV format. Columns found: {list(df.columns)}")

            cursor.execute(
                """
                INSERT INTO dbo.StagingReadings (source_system, source_tag, observed_at, value_raw)
                VALUES (?, ?, ?, ?)
                """,
                source_system,
                source_tag,
                observed_at,
                value_raw,
            )

        conn.commit()
        cursor.close()
        conn.close()

        logging.info("CSV data inserted into SQL")

        # Move file to processed after successful SQL insert
        move_blob(blob_service, container_name, blob_name, "processed")

    except Exception as e:
        logging.exception(f"Function failed: {e}")

        # If processing fails, try moving the file to failed
        try:
            if blob_service and container_name and blob_name:
                move_blob(blob_service, container_name, blob_name, "failed")
        except Exception as move_error:
            logging.exception(f"Failed to move blob to failed folder: {move_error}")

        raise
