-- =====================================================================
-- HOTEL MANAGEMENT SYSTEM — DATABASE SCHEMA (MySQL 8.0+)
-- =====================================================================
-- Covers: room inventory, guest records, staff, reservations, add-on
-- services, and payments — plus views, triggers, and stored procedures
-- that automate the business rules a real hotel needs.
--
-- Run:  mysql -u root -p < hotel_management_system.sql
-- =====================================================================

DROP DATABASE IF EXISTS hotel_management;
CREATE DATABASE hotel_management;
USE hotel_management;

-- =====================================================================
-- SECTION 1: CORE TABLES
-- =====================================================================

-- ---- Room categories (Single, Deluxe, Suite, ...) ----
CREATE TABLE room_types (
    room_type_id   INT AUTO_INCREMENT PRIMARY KEY,
    type_name      VARCHAR(50)  NOT NULL UNIQUE,
    base_price     DECIMAL(10,2) NOT NULL CHECK (base_price > 0),
    max_occupancy  INT NOT NULL CHECK (max_occupancy > 0),
    description    VARCHAR(255)
) ENGINE=InnoDB;

-- ---- Physical rooms ----
CREATE TABLE rooms (
    room_id        INT AUTO_INCREMENT PRIMARY KEY,
    room_number    VARCHAR(10) NOT NULL UNIQUE,
    room_type_id   INT NOT NULL,
    floor_number   INT NOT NULL,
    status         ENUM('Available','Occupied','Maintenance','Reserved')
                   NOT NULL DEFAULT 'Available',
    FOREIGN KEY (room_type_id) REFERENCES room_types(room_type_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE INDEX idx_rooms_status ON rooms(status);

-- ---- Guests ----
CREATE TABLE guests (
    guest_id        INT AUTO_INCREMENT PRIMARY KEY,
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    email           VARCHAR(100) UNIQUE,
    phone           VARCHAR(20) NOT NULL,
    address         VARCHAR(255),
    id_proof_type   VARCHAR(30),
    id_proof_number VARCHAR(50),
    registered_on   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE INDEX idx_guests_phone ON guests(phone);

-- ---- Employees / staff ----
CREATE TABLE employees (
    employee_id  INT AUTO_INCREMENT PRIMARY KEY,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(50) NOT NULL,
    position     VARCHAR(50) NOT NULL,
    department   VARCHAR(50),
    phone        VARCHAR(20),
    email        VARCHAR(100) UNIQUE,
    salary       DECIMAL(10,2) CHECK (salary >= 0),
    hire_date    DATE NOT NULL
) ENGINE=InnoDB;

-- ---- Reservations (the central booking record) ----
CREATE TABLE reservations (
    reservation_id  INT AUTO_INCREMENT PRIMARY KEY,
    guest_id        INT NOT NULL,
    room_id         INT NOT NULL,
    employee_id     INT,                       -- who took the booking
    check_in_date   DATE NOT NULL,
    check_out_date  DATE NOT NULL,
    num_guests      INT NOT NULL DEFAULT 1,
    status          ENUM('Confirmed','CheckedIn','CheckedOut','Cancelled')
                    NOT NULL DEFAULT 'Confirmed',
    booking_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_dates CHECK (check_out_date > check_in_date),
    FOREIGN KEY (guest_id)    REFERENCES guests(guest_id),
    FOREIGN KEY (room_id)     REFERENCES rooms(room_id),
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
) ENGINE=InnoDB;

CREATE INDEX idx_reservations_dates ON reservations(room_id, check_in_date, check_out_date);
CREATE INDEX idx_reservations_status ON reservations(status);

-- ---- Add-on services (laundry, spa, room service, ...) ----
CREATE TABLE services (
    service_id    INT AUTO_INCREMENT PRIMARY KEY,
    service_name  VARCHAR(100) NOT NULL UNIQUE,
    price         DECIMAL(10,2) NOT NULL CHECK (price >= 0)
) ENGINE=InnoDB;

-- ---- Services used per reservation (many-to-many + usage data) ----
CREATE TABLE reservation_services (
    reservation_service_id INT AUTO_INCREMENT PRIMARY KEY,
    reservation_id  INT NOT NULL,
    service_id      INT NOT NULL,
    quantity        INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
    used_on         DATE NOT NULL,
    FOREIGN KEY (reservation_id) REFERENCES reservations(reservation_id)
        ON DELETE CASCADE,
    FOREIGN KEY (service_id) REFERENCES services(service_id)
) ENGINE=InnoDB;

-- ---- Payments against a reservation ----
CREATE TABLE payments (
    payment_id      INT AUTO_INCREMENT PRIMARY KEY,
    reservation_id  INT NOT NULL,
    amount          DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    payment_date    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    payment_method  ENUM('Cash','Card','Online','BankTransfer') NOT NULL,
    payment_status  ENUM('Pending','Completed','Refunded') NOT NULL DEFAULT 'Completed',
    FOREIGN KEY (reservation_id) REFERENCES reservations(reservation_id)
) ENGINE=InnoDB;

-- =====================================================================
-- SECTION 2: TRIGGERS  (business rules enforced by the database itself)
-- =====================================================================

DELIMITER $$

-- Reject a new reservation if the room is already booked for an
-- overlapping date range (only active bookings block the room).
CREATE TRIGGER trg_prevent_double_booking
BEFORE INSERT ON reservations
FOR EACH ROW
BEGIN
    DECLARE conflict_count INT;
    SELECT COUNT(*) INTO conflict_count
    FROM reservations
    WHERE room_id = NEW.room_id
      AND status IN ('Confirmed','CheckedIn')
      AND NEW.check_in_date < check_out_date
      AND NEW.check_out_date > check_in_date;

    IF conflict_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Room is already booked for the selected dates.';
    END IF;
END$$

-- Keep room.status in sync whenever a reservation's status changes.
CREATE TRIGGER trg_sync_room_status
AFTER UPDATE ON reservations
FOR EACH ROW
BEGIN
    IF NEW.status = 'CheckedIn' AND OLD.status <> 'CheckedIn' THEN
        UPDATE rooms SET status = 'Occupied' WHERE room_id = NEW.room_id;
    ELSEIF NEW.status IN ('CheckedOut','Cancelled') AND OLD.status <> NEW.status THEN
        UPDATE rooms SET status = 'Available' WHERE room_id = NEW.room_id;
    END IF;
END$$

-- A freshly confirmed reservation reserves the room right away.
CREATE TRIGGER trg_reserve_on_booking
AFTER INSERT ON reservations
FOR EACH ROW
BEGIN
    IF NEW.status = 'Confirmed' THEN
        UPDATE rooms SET status = 'Reserved' WHERE room_id = NEW.room_id;
    END IF;
END$$

DELIMITER ;

-- =====================================================================
-- SECTION 3: STORED PROCEDURES
-- =====================================================================

DELIMITER $$

-- Book a room after confirming it is actually free for those dates.
-- (trg_prevent_double_booking is a second line of defense.)
CREATE PROCEDURE sp_book_room (
    IN p_guest_id     INT,
    IN p_room_id      INT,
    IN p_employee_id  INT,
    IN p_check_in     DATE,
    IN p_check_out    DATE,
    IN p_num_guests   INT
)
BEGIN
    DECLARE conflict_count INT;

    SELECT COUNT(*) INTO conflict_count
    FROM reservations
    WHERE room_id = p_room_id
      AND status IN ('Confirmed','CheckedIn')
      AND p_check_in < check_out_date
      AND p_check_out > check_in_date;

    IF conflict_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Room is not available for the selected dates.';
    ELSE
        INSERT INTO reservations
            (guest_id, room_id, employee_id, check_in_date, check_out_date, num_guests)
        VALUES
            (p_guest_id, p_room_id, p_employee_id, p_check_in, p_check_out, p_num_guests);
        SELECT LAST_INSERT_ID() AS new_reservation_id;
    END IF;
END$$

-- Mark a reservation checked out and return its final bill
-- (room charge for the stayed nights + every service used).
CREATE PROCEDURE sp_checkout (
    IN p_reservation_id INT
)
BEGIN
    DECLARE room_total DECIMAL(10,2);
    DECLARE service_total DECIMAL(10,2);

    UPDATE reservations SET status = 'CheckedOut' WHERE reservation_id = p_reservation_id;

    SELECT rt.base_price * DATEDIFF(r.check_out_date, r.check_in_date)
      INTO room_total
    FROM reservations r
    JOIN rooms rm       ON rm.room_id = r.room_id
    JOIN room_types rt  ON rt.room_type_id = rm.room_type_id
    WHERE r.reservation_id = p_reservation_id;

    SELECT COALESCE(SUM(s.price * rs.quantity), 0) INTO service_total
    FROM reservation_services rs
    JOIN services s ON s.service_id = rs.service_id
    WHERE rs.reservation_id = p_reservation_id;

    SELECT room_total AS room_charges,
           service_total AS service_charges,
           room_total + service_total AS total_due;
END$$

DELIMITER ;

-- =====================================================================
-- SECTION 4: VIEWS  (ready-made answers to common front-desk questions)
-- =====================================================================

-- Rooms free to sell right now
CREATE VIEW vw_available_rooms AS
SELECT r.room_id, r.room_number, rt.type_name, rt.base_price, r.floor_number
FROM rooms r
JOIN room_types rt ON rt.room_type_id = r.room_type_id
WHERE r.status = 'Available';

-- Everyone currently staying in the hotel
CREATE VIEW vw_current_guests AS
SELECT g.guest_id, g.first_name, g.last_name, g.phone,
       r.room_number, res.check_in_date, res.check_out_date
FROM reservations res
JOIN guests g ON g.guest_id = res.guest_id
JOIN rooms r  ON r.room_id = res.room_id
WHERE res.status = 'CheckedIn';

-- Full bill per reservation: room charges + services
CREATE VIEW vw_reservation_bill AS
SELECT
    res.reservation_id,
    g.first_name, g.last_name,
    r.room_number,
    res.check_in_date, res.check_out_date,
    DATEDIFF(res.check_out_date, res.check_in_date) AS nights,
    rt.base_price * DATEDIFF(res.check_out_date, res.check_in_date) AS room_charges,
    COALESCE((
        SELECT SUM(s.price * rs.quantity)
        FROM reservation_services rs
        JOIN services s ON s.service_id = rs.service_id
        WHERE rs.reservation_id = res.reservation_id
    ), 0) AS service_charges,
    rt.base_price * DATEDIFF(res.check_out_date, res.check_in_date)
        + COALESCE((
            SELECT SUM(s.price * rs.quantity)
            FROM reservation_services rs
            JOIN services s ON s.service_id = rs.service_id
            WHERE rs.reservation_id = res.reservation_id
        ), 0) AS total_due
FROM reservations res
JOIN guests g      ON g.guest_id = res.guest_id
JOIN rooms r       ON r.room_id = res.room_id
JOIN room_types rt ON rt.room_type_id = r.room_type_id;

-- Daily occupancy snapshot
CREATE VIEW vw_occupancy_summary AS
SELECT
    (SELECT COUNT(*) FROM rooms) AS total_rooms,
    SUM(status = 'Occupied')     AS occupied,
    SUM(status = 'Reserved')     AS reserved,
    SUM(status = 'Available')    AS available,
    SUM(status = 'Maintenance')  AS under_maintenance
FROM rooms;

-- =====================================================================
-- SECTION 5: SAMPLE DATA
-- =====================================================================

INSERT INTO room_types (type_name, base_price, max_occupancy, description) VALUES
('Single',      4500.00, 1, 'One single bed, city view'),
('Deluxe',      8500.00, 2, 'Queen bed, work desk, minibar'),
('Suite',      15000.00, 4, 'Separate living area, premium amenities');

INSERT INTO rooms (room_number, room_type_id, floor_number, status) VALUES
('101', 1, 1, 'Available'),
('102', 1, 1, 'Available'),
('201', 2, 2, 'Available'),
('202', 2, 2, 'Available'),
('301', 3, 3, 'Available');

INSERT INTO employees (first_name, last_name, position, department, phone, email, salary, hire_date) VALUES
('Ayesha', 'Malik', 'Front Desk Manager', 'Front Office', '03001112222', 'ayesha.malik@hotel.com', 85000.00, '2022-03-01'),
('Bilal',  'Ahmed', 'Receptionist',       'Front Office', '03003334444', 'bilal.ahmed@hotel.com',  45000.00, '2023-06-15');

INSERT INTO guests (first_name, last_name, email, phone, address, id_proof_type, id_proof_number) VALUES
('Hamza',  'Iqbal',  'hamza.iqbal@example.com',  '03211234567', 'Lahore, Pakistan',    'CNIC', '35202-1234567-1'),
('Fatima', 'Sheikh', 'fatima.sheikh@example.com','03217654321', 'Karachi, Pakistan',   'CNIC', '42101-7654321-2');

INSERT INTO services (service_name, price) VALUES
('Laundry',        800.00),
('Airport Pickup', 2500.00),
('Spa Session',    3500.00);

-- =====================================================================
-- SECTION 6: EXAMPLE USAGE
-- =====================================================================

-- Book room 201 (Deluxe) for Hamza, 3 nights, via the safe procedure:
-- CALL sp_book_room(1, 3, 2, '2026-08-10', '2026-08-13', 2);

-- Check the guest into the room they booked:
-- UPDATE reservations SET status = 'CheckedIn' WHERE reservation_id = 1;

-- Add a service they used during their stay:
-- INSERT INTO reservation_services (reservation_id, service_id, quantity, used_on)
-- VALUES (1, 1, 2, '2026-08-11');

-- Check them out and get the final bill:
-- CALL sp_checkout(1);

-- Front-desk dashboard queries:
-- SELECT * FROM vw_available_rooms;
-- SELECT * FROM vw_current_guests;
-- SELECT * FROM vw_reservation_bill;
-- SELECT * FROM vw_occupancy_summary;
