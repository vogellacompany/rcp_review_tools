#!/usr/bin/env python3
import sys
import re

def parse_time(time_str):
    """Parses a time string like '5.990 s' or '01:50 min' or '1.5 min' into seconds."""
    time_str = time_str.strip()

    # Try to match 'MM:SS min' format, e.g., '01:50 min'
    match = re.fullmatch(r'(\d+):(\d+(?:\.\d+)?)\s*min', time_str)
    if match:
        minutes = float(match.group(1))
        seconds = float(match.group(2))
        return minutes * 60 + seconds

    # Try to match 'X.Y min' format, e.g., '1.5 min'
    match = re.fullmatch(r'(\d+(?:\.\d+)?)\s*min', time_str)
    if match:
        return float(match.group(1)) * 60

    # Try to match 'X.Y s' format, e.g., '5.990 s'
    match = re.fullmatch(r'(\d+(?:\.\d+)?)\s*s', time_str)
    if match:
        return float(match.group(1))

    return 0.0

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 analyze_build_times.py <path_to_build_output_file>", file=sys.stderr)
        sys.exit(1)

    file_path = sys.argv[1]
    
    try:
        with open(file_path, 'r') as f:
            for line in f:
                # Placeholder for actual processing logic, as it was not provided in the snippets.
                # The script would likely parse lines for build times and other metrics here.
                pass
        
        print(f"Successfully processed {file_path}") # This line might change once the actual logic is added

    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
