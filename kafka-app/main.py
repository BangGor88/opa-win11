import os
import json
import httpx
from fastapi import FastAPI, Header, HTTPException
from aiokafka import AIOKafkaProducer, AIOKafkaConsumer

app = FastAPI(title="Kafka OPA Gateway")

OPA_URL = os.getenv("OPA_URL", "http://localhost:8181")
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "localhost:9092")

async def check_opa(role: str, action: str, resource: str) -> bool:
    payload = {"input": {"user": {"role": role}, "action": action, "resource": resource}}
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{OPA_URL}/v1/data/kafka/authz/allow",
            json=payload,
            timeout=5
        )
        resp.raise_for_status()
        return resp.json().get("result", False)

@app.post("/publish/{topic}")
async def publish(topic: str, message: dict, x_user_role: str = Header(default="viewer")):
    if not await check_opa(x_user_role, "publish", topic):
        raise HTTPException(403, detail=f"OPA denied: role={x_user_role} action=publish topic={topic}")
    producer = AIOKafkaProducer(bootstrap_servers=KAFKA_BOOTSTRAP)
    await producer.start()
    try:
        await producer.send_and_wait(topic, json.dumps(message).encode())
    finally:
        await producer.stop()
    return {"status": "published", "topic": topic, "role": x_user_role}

@app.get("/consume/{topic}")
async def consume(topic: str, x_user_role: str = Header(default="viewer")):
    if not await check_opa(x_user_role, "consume", topic):
        raise HTTPException(403, detail=f"OPA denied: role={x_user_role} action=consume topic={topic}")
    consumer = AIOKafkaConsumer(
        topic,
        bootstrap_servers=KAFKA_BOOTSTRAP,
        auto_offset_reset="earliest",
        consumer_timeout_ms=3000,
        enable_auto_commit=False,
        group_id=None
    )
    await consumer.start()
    messages = []
    try:
        async for msg in consumer:
            messages.append(json.loads(msg.value.decode()))
            if len(messages) >= 5:
                break
    except Exception:
        pass
    finally:
        await consumer.stop()
    return {"status": "ok", "topic": topic, "role": x_user_role, "messages": messages}