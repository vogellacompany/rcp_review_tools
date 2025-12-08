#!/usr/bin/env python3
import sys
import re
import argparse

# Pre-compile regex for performance
# Matches:
# - Optional minutes part: (?:(\d+):)?
# - Value part (seconds or decimal minutes): (\d+(?:\.\d+)?)
# - Unit: \s*(min|s)
RE_TIME = re.compile(r'(?:(\d+):)?(\d+(?:\.\d+)?)\s*(min|s)')

def parse_time(time_str):
    """Parses a time string like '5.990 s' or '01:50 min' or '1.5 min' into seconds."""
    time_str = time_str.strip()

    match = RE_TIME.fullmatch(time_str)
    if not match:
        raise ValueError(f"Could not parse time string: '{time_str}'")

    minutes_str, value_str, unit = match.groups()

    if unit == 's':
        # Seconds format should not have a minutes part, e.g., '1:5.990 s'
        if minutes_str:
            raise ValueError(f"Invalid time format for seconds: '{time_str}'")
        return float(value_str)

    # unit must be 'min'
    if minutes_str:
        # MM:SS.ms min format
        return float(minutes_str) * 60 + float(value_str)
    else:
        # X.Y min format
        return float(value_str) * 60

def main():
    parser = argparse.ArgumentParser(description="Analyze build times from a build output file.")
    parser.add_argument("file_path", help="Path to the build output file.")
    args = parser.parse_args()

    file_path = args.file_path
    
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
    except OSError as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
