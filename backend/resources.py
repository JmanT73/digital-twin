from pypdf import PdfReader
import json
import os

# Get the directory where this file is located
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")

# Read LinkedIn PDF
try:
    linkedin_path = os.path.join(DATA_DIR, "linkedin.pdf")
    reader = PdfReader(linkedin_path)
    linkedin = ""
    for page in reader.pages:
        text = page.extract_text()
        if text:
            linkedin += text
except FileNotFoundError:
    linkedin = "LinkedIn profile not available"

# Read other data files
try:
    with open(os.path.join(DATA_DIR, "summary.txt"), "r", encoding="utf-8") as f:
        summary = f.read()
except FileNotFoundError:
    summary = "Summary not available"

try:
    with open(os.path.join(DATA_DIR, "style.txt"), "r", encoding="utf-8") as f:
        style = f.read()
except FileNotFoundError:
    style = "Style not available"

try:
    with open(os.path.join(DATA_DIR, "facts.json"), "r", encoding="utf-8") as f:
        facts = json.load(f)
except FileNotFoundError:
    facts = {"name": "Unknown", "full_name": "Unknown"}