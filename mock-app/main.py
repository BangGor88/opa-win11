import os
import httpx
from fastapi import FastAPI, Header, HTTPException

app = FastAPI(title="Mock Catalog Service")

OPA_URL = os.getenv("OPA_URL", "http://localhost:8181")

async def check_opa(role: str, action: str, resource: str) -> bool:
    payload = {"input": {"user": {"role": role}, "action": action, "resource": resource}}
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{OPA_URL}/v1/data/openmetadata/authz/allow",
            json=payload,
            timeout=5
        )
        resp.raise_for_status()
        return resp.json().get("result", False)

@app.get("/catalog/{resource}")
async def get_resource(resource: str, x_user_role: str = Header(default="viewer")):
    if not await check_opa(x_user_role, "read", resource):
        raise HTTPException(403, detail=f"OPA denied: role={x_user_role} action=read resource={resource}")
    return {"status": "allowed", "resource": resource, "role": x_user_role, "action": "read"}

@app.post("/catalog/{resource}")
async def write_resource(resource: str, x_user_role: str = Header(default="viewer")):
    if not await check_opa(x_user_role, "write", resource):
        raise HTTPException(403, detail=f"OPA denied: role={x_user_role} action=write resource={resource}")
    return {"status": "allowed", "resource": resource, "role": x_user_role, "action": "write"}

@app.delete("/catalog/{resource}")
async def delete_resource(resource: str, x_user_role: str = Header(default="viewer")):
    if not await check_opa(x_user_role, "delete", resource):
        raise HTTPException(403, detail=f"OPA denied: role={x_user_role} action=delete resource={resource}")
    return {"status": "allowed", "resource": resource, "role": x_user_role, "action": "delete"}

@app.get("/health")
async def health():
    return {"status": "ok"}