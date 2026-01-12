"""
Callback functionality for real-time query status updates.

This module provides support for sending query execution status updates
to external APIs for UI display and monitoring.
"""

import requests
from datetime import date, datetime
from dataclasses import dataclass
from os import environ
from typing import Optional

from dbt_common.dataclass_schema import dbtClassMixin
from dbt.adapters.events.logging import AdapterLogger

logger = AdapterLogger("BigQuery")


@dataclass
class PartitionsModelResp(dbtClassMixin):
    """
    Data class for partition model execution response.

    Contains metadata about query execution including BigQuery metrics,
    dates, and execution status.
    """
    unique_id: str
    job_id: Optional[str] = None
    dry_run: bool = False
    status: Optional[str] = None
    start_date: Optional[date] = None
    end_date: Optional[date] = None
    bytes_billed: Optional[int] = None
    bytes_processed: Optional[int] = None
    slot_ms: Optional[int] = None
    success: Optional[bool] = None
    error: Optional[str] = None
    started: Optional[datetime] = None
    ended: Optional[datetime] = None


def post_query_status(query_status: PartitionsModelResp) -> None:
    """
    Post query execution status to external API endpoint.

    This function sends real-time updates about query execution to an
    external API for monitoring and UI display. The callback is wrapped
    in try/except to prevent failures from breaking the dbt run.

    Environment variables:
        DBT_URL: Base URL for the API endpoint
        API_KEY: Authentication key for API requests

    Args:
        query_status: PartitionsModelResp object containing execution metadata

    Returns:
        None
    """
    dbt_url = environ.get('DBT_URL', '')
    api_key = environ.get('API_KEY', '')

    # Skip if not configured
    if not dbt_url or not api_key:
        logger.debug("Skipping callback: DBT_URL or API_KEY not configured")
        return

    api_path = 'dbt/set_query_status'
    url = f'{dbt_url.rstrip("/")}/{api_path}'

    try:
        logger.debug(f'dbt_connector: POSTing to {url} with payload {query_status}')

        response = requests.post(
            url=url,
            json=query_status.to_dict(),
            headers={'X-API-KEY': api_key},
            timeout=10  # Add timeout to prevent hanging
        )

        if response.status_code != 200:
            error = response.json() if response.headers.get('content-type') == 'application/json' else response.text
            logger.warning(f'dbt_connector: got status {response.status_code}, error: {error}')
        else:
            logger.debug(f'dbt_connector: successfully posted status update')

    except requests.exceptions.Timeout:
        logger.error('dbt_connector: callback request timed out')
    except requests.exceptions.ConnectionError as e:
        logger.error(f'dbt_connector: connection error during callback: {e}')
    except Exception as e:
        logger.error(f'dbt_connector: unexpected error during callback: {e}')
