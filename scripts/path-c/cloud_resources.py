"""Sample aggregate process RSS and free workspace disk on an ephemeral hosted VM."""
import datetime
import json
import shutil
import subprocess
import time

while True:
    rss = subprocess.check_output(['ps', '-axo', 'rss='], text=True)
    values = [int(value) for value in rss.split()]
    print(json.dumps({
        'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'aggregate_process_rss_kib': sum(values),
        'largest_process_rss_kib': max(values, default=0),
        'disk_free_bytes': shutil.disk_usage('.').free,
    }), flush=True)
    time.sleep(10)
