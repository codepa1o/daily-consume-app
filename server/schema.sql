CREATE TABLE IF NOT EXISTS users (
  id BIGSERIAL PRIMARY KEY,
  username VARCHAR(32) NOT NULL,
  username_key VARCHAR(32) NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  nickname VARCHAR(32) NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE users ADD COLUMN IF NOT EXISTS gender TEXT NOT NULL DEFAULT 'unset'
  CHECK (gender IN ('unset', 'male', 'female'));
CREATE TABLE IF NOT EXISTS female_health_settings (
  user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  cycle_length SMALLINT CHECK (cycle_length BETWEEN 1 AND 365),
  period_length SMALLINT CHECK (period_length BETWEEN 1 AND 90),
  paused BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE IF NOT EXISTS menstrual_periods (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  start_date DATE NOT NULL,
  end_date DATE CHECK (end_date >= start_date),
  bleeding_dates JSONB NOT NULL,
  UNIQUE (user_id, start_date)
);
CREATE TABLE IF NOT EXISTS female_health_days (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  flow TEXT NOT NULL CHECK (flow IN ('none','light','medium','heavy')),
  pain SMALLINT NOT NULL CHECK (pain BETWEEN 0 AND 3),
  symptoms JSONB NOT NULL,
  mood TEXT NOT NULL,
  spotting BOOLEAN NOT NULL DEFAULT FALSE,
  notes VARCHAR(2000) NOT NULL,
  PRIMARY KEY (user_id, date)
);
CREATE TABLE IF NOT EXISTS user_sessions (
  token_hash CHAR(64) PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS user_sessions_user ON user_sessions(user_id);
CREATE INDEX IF NOT EXISTS user_sessions_expiry ON user_sessions(expires_at);
CREATE TABLE IF NOT EXISTS weight_entries (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  grams INTEGER NOT NULL CHECK (grams BETWEEN 20000 AND 300000),
  PRIMARY KEY (user_id, date)
);
CREATE TABLE IF NOT EXISTS height_entries (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  millimeters INTEGER NOT NULL CHECK (millimeters BETWEEN 800 AND 2500),
  PRIMARY KEY (user_id, date)
);
CREATE TABLE IF NOT EXISTS meal_entries (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  meal_type TEXT NOT NULL CHECK (meal_type IN ('早餐','午餐','晚餐')),
  foods TEXT NOT NULL CHECK (length(foods) BETWEEN 1 AND 2000),
  expense_cents BIGINT NOT NULL CHECK (expense_cents BETWEEN 0 AND 10000000000),
  PRIMARY KEY (user_id, date, meal_type)
);
CREATE TABLE IF NOT EXISTS workout_muscles (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name VARCHAR(12) NOT NULL,
  color_value BIGINT NOT NULL CHECK (color_value BETWEEN 0 AND 4294967295),
  built_in SMALLINT NOT NULL DEFAULT 0 CHECK (built_in IN (0,1)),
  PRIMARY KEY (user_id, name)
);
CREATE TABLE IF NOT EXISTS workout_plans (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  weekday SMALLINT NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  muscles JSONB NOT NULL,
  is_rest SMALLINT NOT NULL DEFAULT 0 CHECK (is_rest IN (0,1)),
  PRIMARY KEY (user_id, weekday)
);
CREATE TABLE IF NOT EXISTS workout_logs (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  muscles JSONB NOT NULL,
  PRIMARY KEY (user_id, date)
);
CREATE TABLE IF NOT EXISTS workout_settings (
  user_id BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  weekly_goal SMALLINT NOT NULL DEFAULT 3 CHECK (weekly_goal BETWEEN 1 AND 7)
);
CREATE TABLE IF NOT EXISTS legacy_imports (
  import_id CHAR(64) PRIMARY KEY,
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  counts JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
