import json
import requests
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

API_URL = "https://opensky-network.org/api/states/all"

def handler(event: dict, context: object) -> list:
    logger.info("Fetching live flight data from OpenSky Network...")

    try:
        response = requests.get(API_URL, timeout=10)
        response.raise_for_status()

        data = response.json()
        flight_list = []

        if data.get("states"):
            for flight_state in data["states"]:
                flight_list.append({
                    "callsign": str(flight_state[1]).strip() if flight_state[1] else None,
                    "origin_country": str(flight_state[2]) if flight_state[2] else None,
                    "longitude": float(flight_state[5]) if flight_state[5] else None,
                    "latitude": float(flight_state[6]) if flight_state[6] else None,
                    "baro_altitude_m": float(flight_state[7]) if flight_state[7] else None,
                    "on_ground": bool(flight_state[8]),
                    "velocity_mps": float(flight_state[9]) if flight_state[9] else None,
                    "true_track_deg": float(flight_state[10]) if flight_state[10] else None,
                    "vertical_rate_mps": float(flight_state[11]) if flight_state[11] else None,
                    "geo_altitude_m": float(flight_state[13]) if flight_state[13] else None,
                })

        logger.info(f"Successfully fetched and transformed {len(flight_list)} flights.")
        return flight_list

    except requests.exceptions.Timeout as e:
        logger.error(f"Request to OpenSky API timed out: {e}")
        raise Exception("Request timed out")
        
    except requests.exceptions.RequestException as e:
        logger.error(f"API request failed: {e}")
        raise Exception(f"API request failed: {e}")
        
    except Exception as e:
        logger.error(f"An unexpected error occurred: {e}", exc_info=True)
        raise Exception(f"An unexpected error occurred: {e}")
