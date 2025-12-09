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
        build_times = []
        # Regex to match lines like:
        # [INFO] de.ruv.ruvconn.all.releng .......................... SUCCESS [  5.419 s]
        # [INFO] de.ruv.ruvconn.basis.common.model .................. SUCCESS [01:02 min]
        line_regex = re.compile(r'^\[INFO\]\s+(.+?)\s+\.{3,}\s+(\w+)\s+\[(.+?)\]$')

        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                match = line_regex.match(line)
                if match:
                    module_name = match.group(1)
                    status = match.group(2)
                    time_str = match.group(3)
                    
                    try:
                        seconds = parse_time(time_str)
                        build_times.append({
                            'name': module_name,
                            'status': status,
                            'time_str': time_str,
                            'seconds': seconds
                        })
                    except ValueError:
                        # Might match a line that isn't a time, though the regex is fairly specific
                        continue

        if not build_times:
            print(f"No build time information found in '{file_path}'.", file=sys.stderr)
            sys.exit(0)

        # Sort by duration descending
        build_times.sort(key=lambda x: x['seconds'], reverse=True)

        print(f"{'Module':<60} | {'Status':<10} | {'Time'}")
        print("-" * 90)
        
        total_seconds = 0
        for entry in build_times:
            total_seconds += entry['seconds']
            print(f"{entry['name']:<60} | {entry['status']:<10} | {entry['time_str']}")

        print("-" * 90)
        print(f"Total time: {total_seconds:.2f} s ({total_seconds/60:.2f} min)")

    except FileNotFoundError:
        print(f"Error: File '{file_path}' not found.", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
