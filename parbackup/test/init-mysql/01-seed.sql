-- Allow testuser to drop/recreate databases (needed for restore round-trip).
GRANT ALL PRIVILEGES ON *.* TO 'testuser'@'%';
FLUSH PRIVILEGES;

USE testdb;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(200) NOT NULL
);

INSERT INTO users (name, email) VALUES
    ('Alice Mueller', 'alice@example.com'),
    ('Bob Schmidt', 'bob@example.com'),
    ('Charlie Weber', 'charlie@example.com');
