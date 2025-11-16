import json
import logging
import requests
from requests.auth import HTTPBasicAuth

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ES_HOST = "http://elasticsearch:9200"
ES_USER = "elastic"
ES_PASSWORD = "changeme"
INDEX_NAME = "flights"

KIBANA_HOST = "http://kibana:5601"
KIBANA_AUTH = HTTPBasicAuth("kibana_user_test", "newpassword")
KIBANA_DATAVIEW_ID = "flights"
KIBANA_HEADERS = {"kbn-xsrf": "true", "Content-Type": "application/json"}

ES_AUTH = HTTPBasicAuth(ES_USER, ES_PASSWORD)

FLIGHT_MAPPING = {
    "mappings": {
        "properties": {
            "icao24": {"type": "keyword"},
            "callsign": {"type": "keyword"},
            "origin_country": {"type": "keyword"},
            "on_ground": {"type": "boolean"},
            "velocity_mps": {"type": "float"},
            "true_track_deg": {"type": "float"},
            "vertical_rate_mps": {"type": "float"},
            "baro_altitude_m": {"type": "float"},
            "geo_altitude_m": {"type": "float"},
            "location": {"type": "geo_point"}
        }
    }
}

_index_created = False
_data_view_created = False

def ensure_index_exists():
    global _index_created
    if _index_created:
        return

    index_url = f"{ES_HOST}/{INDEX_NAME}"
    
    try:
        response = requests.head(index_url, auth=ES_AUTH, verify=False, timeout=5)

        if response.status_code == 404:
            logger.info(f"Index '{INDEX_NAME}' not found. Creating...")
            
            create_response = requests.put(
                index_url,
                auth=ES_AUTH,
                json=FLIGHT_MAPPING,
                verify=False,
                timeout=5
            )
            create_response.raise_for_status()
            logger.info(f"Successfully created index '{INDEX_NAME}' with mapping.")
        
        _index_created = True

    except requests.exceptions.ConnectionError as e:
        logger.error(f"Cannot connect to Elasticsearch at {ES_HOST}. Is it running?")
        raise Exception(f"Connection error: {e}")
    except requests.exceptions.RequestException as e:
        logger.error(f"Error checking/creating index '{INDEX_NAME}': {e}")
        raise Exception(f"Error checking/creating index: {e}")

def ensure_data_view_exists():
    global _data_view_created
    if _data_view_created:
        return

    dataview_url = f"{KIBANA_HOST}/api/data_views/data_view/{KIBANA_DATAVIEW_ID}"
    
    try:
        response = requests.get(dataview_url, auth=KIBANA_AUTH, verify=False, timeout=5)
        
        if response.status_code == 404:
            logger.info(f"Data view '{KIBANA_DATAVIEW_ID}' not found. Creating...")
            
            create_url = f"{KIBANA_HOST}/api/data_views/data_view"
            payload = {
                "data_view": {
                    "title": INDEX_NAME,
                    "name": KIBANA_DATAVIEW_ID
                }
            }
            
            create_response = requests.post(
                create_url,
                auth=KIBANA_AUTH,
                headers=KIBANA_HEADERS,
                json=payload,
                verify=False,
                timeout=5
            )
            create_response.raise_for_status()
            logger.info(f"Successfully created data view '{KIBANA_DATAVIEW_ID}'.")
        
        _data_view_created = True

    except requests.exceptions.ConnectionError as e:
        logger.warning(f"Could not connect to Kibana at {KIBANA_HOST}. Data view not created. {e}")
        _data_view_created = True
    except requests.exceptions.RequestException as e:
        logger.error(f"Error checking/creating data view '{KIBANA_DATAVIEW_ID}': {e.response.text}")
        _data_view_created = True


def handler(event: dict, context: object) -> dict:
    
    ensure_index_exists()
    ensure_data_view_exists()

    flight = event
    
    try:
        document_id = flight.get("icao24")
        if not document_id:
            logger.warning("Received flight with no icao24, skipping.")
            return {"statusCode": 200, "body": "Skipped (no 24)"}

        latitude = flight.pop("latitude", None)
        longitude = flight.pop("longitude", None)

        if latitude is not None and longitude is not None:
            flight["location"] = {"lat": latitude, "lon": longitude}
        
        doc_url = f"{ES_HOST}/{INDEX_NAME}/_doc/{document_id}"
        
        response = requests.put(
            doc_url,
            auth=ES_AUTH,
            json=flight,
            verify=False,
            timeout=5
        )
        
        response.raise_for_status()
        
        response_data = response.json()
        logger.info(f"Indexed document {document_id}. Result: {response_data.get('result')}")
        
        return {
            "statusCode": 201,
            "body": json.dumps({
                "message": "Flight indexed successfully",
                "id": document_id,
                "result": response_data.get('result')
            })
        }

    except requests.exceptions.HTTPError as e:
        logger.error(f"HTTP error indexing doc {document_id}: {e.response.text}")
        raise Exception(f"HTTP error: {e.response.text}")
    except Exception as e:
        logger.error(f"An unexpected error occurred for {document_id}: {e}", exc_info=True)
        raise Exception(f"An unexpected error occurred: {e}")