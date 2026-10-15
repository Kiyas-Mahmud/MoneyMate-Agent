from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import create_access_token, get_current_user, hash_password, verify_password
from app.models import Payee, User
from app.services import audit
from app.services.seed import provision_student

router = APIRouter(prefix="/auth", tags=["auth"])


class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=50)
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=2, max_length=120)
    email: str | None = None
    home_country: str = "Bangladesh"
    study_country: str = "China"


class LoginIn(BaseModel):
    username: str
    password: str


def user_view(db: Session, u: User) -> dict:
    uni = db.get(Payee, u.university_payee_id) if u.university_payee_id else None
    return {"id": u.id, "username": u.username, "full_name": u.full_name, "email": u.email, "role": u.role,
            "home_country": u.home_country, "home_currency": u.home_currency, "study_country": u.study_country,
            "study_currency": u.study_currency, "student_id": u.student_id,
            "university": uni.name if uni else None}


@router.post("/register", status_code=201)
def register(body: RegisterIn, db: Session = Depends(get_db)):
    if db.scalar(select(User).where(User.username == body.username)):
        raise HTTPException(400, "Username already taken")
    user = User(username=body.username, password_hash=hash_password(body.password), full_name=body.full_name,
                email=body.email, home_country=body.home_country, study_country=body.study_country)
    db.add(user)
    db.flush()
    provision_student(db, user, with_history=False)
    audit.record(db, user_id=user.id, actor="STUDENT", event="ACCOUNT_CREATED", details={"username": user.username})
    db.commit()
    return {"access_token": create_access_token(user.id, user.role), "user": user_view(db, user)}


@router.post("/login")
def login(body: LoginIn, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.username == body.username))
    if user is None or not verify_password(body.password, user.password_hash):
        raise HTTPException(401, "Incorrect username or password")
    audit.record(db, user_id=user.id, actor="STUDENT", event="LOGIN", details={})
    db.commit()
    return {"access_token": create_access_token(user.id, user.role), "user": user_view(db, user)}


@router.get("/me")
def me(user: User = Depends(get_current_user), db: Session = Depends(get_db)):
    return user_view(db, user)
