CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(200) NOT NULL
);

INSERT INTO users (name, email) VALUES
    ('Alice Mueller', 'alice@example.com'),
    ('Bob Schmidt', 'bob@example.com'),
    ('Charlie Weber', 'charlie@example.com');
