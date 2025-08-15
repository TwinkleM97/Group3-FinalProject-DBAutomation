import argparse, configparser, random, threading, time
from datetime import date, timedelta
import mysql.connector

def load_config(path):
    cfg = configparser.ConfigParser()
    cfg.read(path)
    c = cfg["client"]
    return {
        "host": c.get("host", "127.0.0.1"),
        "user": c.get("user", "root"),
        "password": c.get("password", ""),
        "port": c.getint("port", 3307),
        "database": c.get("database", "project_db"),
    }

def get_conn(params):
    return mysql.connector.connect(
        host=params["host"],
        user=params["user"],
        password=params["password"],
        port=params["port"],
        database=params["database"],
        autocommit=True,
        connection_timeout=10,
    )

LOCATIONS = ["Toronto","Ottawa","Montreal","Vancouver","Calgary"]

ins_count = 0
sel_count = 0
upd_count = 0
lock = threading.Lock()

def insert_worker(params, n=50):
    global ins_count
    conn = get_conn(params); cur = conn.cursor()
    start = date.today() - timedelta(days=30)
    for _ in range(n):
        loc = random.choice(LOCATIONS)
        d = start + timedelta(days=random.randint(0,30))
        temp = round(random.uniform(10, 35), 1)
        precip = round(random.uniform(0, 15), 1)
        hum = round(random.uniform(35, 85), 1)
        cur.execute(
            "INSERT INTO ClimateData (location, record_date, temperature, precipitation, humidity) VALUES (%s,%s,%s,%s,%s)",
            (loc, d, temp, precip, hum),
        )
        with lock: ins_count += 1
    cur.close(); conn.close()

def select_worker(params, n=80):
    global sel_count
    conn = get_conn(params); cur = conn.cursor(dictionary=True)
    for _ in range(n):
        cur.execute("SELECT record_id FROM ClimateData WHERE temperature > 20 ORDER BY record_date DESC LIMIT 50")
        _ = cur.fetchall()
        with lock: sel_count += 1
        time.sleep(0.02)
    cur.close(); conn.close()

def update_worker(params, n=60):
    global upd_count
    conn = get_conn(params); cur = conn.cursor()
    for _ in range(n):
        loc = random.choice(LOCATIONS)
        cur.execute("UPDATE ClimateData SET humidity = LEAST(100, humidity + 2.5) WHERE location = %s", (loc,))
        with lock: upd_count += cur.rowcount if cur.rowcount > 0 else 1
        time.sleep(0.02)
    cur.close(); conn.close()

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=".secrets/mysql.cnf")
    args = ap.parse_args()

    params = load_config(args.config)

    # Warm-up ensure table exists & humidity present
    conn = get_conn(params); cur = conn.cursor()
    cur.execute("SELECT 1 FROM ClimateData LIMIT 1")
    list(cur)
    cur.close(); conn.close()

    threads = []
    for _ in range(3): threads.append(threading.Thread(target=insert_worker, args=(params,)))
    for _ in range(3): threads.append(threading.Thread(target=select_worker, args=(params,)))
    for _ in range(3): threads.append(threading.Thread(target=update_worker, args=(params,)))

    [t.start() for t in threads]
    [t.join() for t in threads]

    print({"inserts": ins_count, "selects": sel_count, "updates": upd_count})
