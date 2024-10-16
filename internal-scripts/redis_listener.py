import redis

def main():
    r = redis.Redis(host='redis-service', port=6379, decode_responses=True)

    pubsub = r.pubsub()
    pubsub.subscribe('file_changes')

    print("Listening for file change messages...")


    try:
        for message in pubsub.listen():
            if message['type'] == 'message':
                print(f"Received message: {message['data']}")
    except KeyboardInterrupt:
        print("Listener stopped.")
    finally:
        pubsub.close()

if __name__ == "__main__":
    main()
