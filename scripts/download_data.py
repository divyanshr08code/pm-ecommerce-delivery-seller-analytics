"""Download the public dataset from Kaggle and extract the CSVs into data/raw/.

Why a script: the raw data is never committed (licence + size), so anyone
reproducing the project needs a way to fetch exactly the same files.
Skips the download when all CSVs are already present.
"""
import sys
import urllib.request
import zipfile
from pathlib import Path

URL = "https://www.kaggle.com/api/v1/datasets/download/olistbr/brazilian-ecommerce"
RAW = Path(__file__).resolve().parent.parent / "data" / "raw"
EXPECTED = [
    "olist_customers_dataset.csv",
    "olist_geolocation_dataset.csv",
    "olist_order_items_dataset.csv",
    "olist_order_payments_dataset.csv",
    "olist_order_reviews_dataset.csv",
    "olist_orders_dataset.csv",
    "olist_products_dataset.csv",
    "olist_sellers_dataset.csv",
    "product_category_name_translation.csv",
]


def main() -> int:
    RAW.mkdir(parents=True, exist_ok=True)
    if all((RAW / name).exists() for name in EXPECTED):
        print("Raw CSVs already present; skipping download.")
        return 0

    archive = RAW / "olist.zip"
    if not archive.exists():
        print(f"Downloading {URL}")
        try:
            urllib.request.urlretrieve(URL, archive)
        except Exception as exc:  # network or login failure: say what to do by hand
            print(f"Download failed: {exc}\nFetch the zip manually from "
                  "https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce "
                  f"and extract the CSVs into {RAW}")
            return 1

    with zipfile.ZipFile(archive) as zf:
        # Extract only the expected names: never trust paths inside an archive.
        for name in EXPECTED:
            zf.extract(name, RAW)
    archive.unlink()
    print(f"Extracted {len(EXPECTED)} CSVs into {RAW}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
