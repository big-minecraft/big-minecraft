import redis
import subprocess
import os
import threading
import time

# Global variables for debounce mechanism
last_event_time = 0
debounce_lock = threading.Lock()
DEBOUNCE_TIME = 5  # Debounce time in seconds
backup_thread = None

def run_backup_script():
    print(f"Running backup script")
    
    backup_script = """
    mkdir -p /mnt/local  # Create local backup directory, if not exists
    apk add --no-cache nfs-utils rsync;
    mount -o nolock,vers=4 nfs-sftp-service.default.svc.cluster.local:/ /mnt/pv || { echo "Mount failed"; exit 1; }
    ls /mnt;

    rm -rf /mnt/local/*;  # Delete everything in /mnt/local if it exists
    rsync -av --exclude '/mnt/local' /mnt/pv/ /mnt/local/;
    """

    # Use subprocess to run the script
    process = subprocess.Popen(['/bin/sh', '-c', backup_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = process.communicate()

    if process.returncode != 0:
        print(f"Error running backup script: {stderr.decode()}")
    else:
        print(f"Backup script output: {stdout.decode()}")

def debounce_backup():
    global last_event_time, backup_thread

    while True:
        current_time = time.time()

        # If enough time has passed since the last event, run the backup
        with debounce_lock:
            if current_time - last_event_time >= DEBOUNCE_TIME:
                print("Debounced - running backup")
                run_backup_script()
                last_event_time = 0  # Reset the event timer after running the backup
                backup_thread = None
                return

        time.sleep(1)  # Sleep for a second and check again

def reset_debounce_timer():
    global last_event_time, backup_thread

    with debounce_lock:
        last_event_time = time.time()

    # Start the backup thread if it's not already running
    if backup_thread is None:
        backup_thread = threading.Thread(target=debounce_backup)
        backup_thread.start()

def main():
    # Run an initial backup when the script starts
    run_backup_script()

    # Connect to Redis
    r = redis.Redis(host='redis-service', port=6379, decode_responses=True)

    pubsub = r.pubsub()
    pubsub.subscribe('file_changes')

    print("Listening for file change messages...")

    try:
        for message in pubsub.listen():
            if message['type'] == 'message':
                print(f"Received message: {message['data']}")
                reset_debounce_timer()  # Reset the debounce timer on each received message

    except KeyboardInterrupt:
        print("Listener stopped.")
    finally:
        if backup_thread is not None:
            backup_thread.join()  # Ensure the backup thread finishes before exiting
        pubsub.close()

if __name__ == "__main__":
    main()
