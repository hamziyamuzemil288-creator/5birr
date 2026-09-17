-- PART 4 of 4: Triggers, Seed Data, Grants
-- Paste into Supabase SQL Editor and run AFTER Part 3.

DO $$ BEGIN CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_updated BEFORE UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_updated BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_ride_requests_updated BEFORE UPDATE ON ride_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallets_updated BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_subscriptions_updated BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_categories_updated BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_stores_updated BEFORE UPDATE ON provider_stores FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_gallery_updated BEFORE UPDATE ON provider_gallery FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_methods_updated BEFORE UPDATE ON payment_methods FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_recharge_requests_updated BEFORE UPDATE ON wallet_recharge_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_notifications_security BEFORE INSERT ON notifications FOR EACH ROW EXECUTE FUNCTION prevent_notification_injection(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_auto_approval_request AFTER INSERT ON profiles FOR EACH ROW EXECUTE FUNCTION auto_create_user_approval_request(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_auto_setup AFTER INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION handle_new_provider_profile(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_driver_status AFTER UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION auto_create_driver_status(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_driver_status_insert AFTER INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION auto_create_driver_status_insert(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_support_tickets_security BEFORE INSERT OR UPDATE ON support_tickets FOR EACH ROW EXECUTE FUNCTION prevent_support_ticket_status_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_agreements_security BEFORE UPDATE ON payment_agreements FOR EACH ROW EXECUTE FUNCTION prevent_payment_agreement_unaccept(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_vehicles_insert_security BEFORE INSERT ON vehicles FOR EACH ROW EXECUTE FUNCTION prevent_vehicle_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_insert_security BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION prevent_product_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_reviews_insert_security BEFORE INSERT ON reviews FOR EACH ROW EXECUTE FUNCTION prevent_review_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_insert_security BEFORE INSERT ON orders FOR EACH ROW EXECUTE FUNCTION prevent_order_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_ride_requests_insert_security BEFORE INSERT ON ride_requests FOR EACH ROW EXECUTE FUNCTION prevent_ride_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_insert_security BEFORE INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION prevent_provider_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_insert_security BEFORE INSERT ON profiles FOR EACH ROW EXECUTE FUNCTION prevent_profile_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_security BEFORE UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION prevent_provider_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_security BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION prevent_profile_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_vehicles_security BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION prevent_vehicle_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_proofs_security BEFORE UPDATE ON payment_proofs FOR EACH ROW EXECUTE FUNCTION prevent_payment_proof_self_verification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_security BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION prevent_order_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_subscriptions_security BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION prevent_subscription_self_modification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_user_roles_security BEFORE INSERT OR UPDATE OR DELETE ON user_roles FOR EACH ROW EXECUTE FUNCTION prevent_role_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallets_security BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION prevent_wallet_direct_balance_edit(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_system_settings_security BEFORE INSERT OR UPDATE OR DELETE ON system_settings FOR EACH ROW EXECUTE FUNCTION prevent_system_settings_self_modification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_audit_logs_immutable BEFORE DELETE ON audit_logs FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_deletion(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallet_transactions_immutable BEFORE UPDATE ON wallet_transactions FOR EACH ROW EXECUTE FUNCTION prevent_wallet_txn_mutation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_approval_history_immutable BEFORE UPDATE OR DELETE ON approval_history FOR EACH ROW EXECUTE FUNCTION prevent_approval_history_mutation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_listing_status_security BEFORE UPDATE ON products FOR EACH ROW WHEN (NEW.listing_status IS DISTINCT FROM OLD.listing_status) EXECUTE FUNCTION prevent_inactive_provider_publish(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_listing_status_security_insert BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION prevent_inactive_provider_publish_insert(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_reviews_product_rating AFTER INSERT OR UPDATE OR DELETE ON reviews FOR EACH ROW EXECUTE FUNCTION update_product_rating(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_sync_store_count AFTER INSERT OR DELETE ON products FOR EACH ROW EXECUTE FUNCTION sync_store_listing_count(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_sync_store_count_status AFTER UPDATE ON products FOR EACH ROW WHEN (NEW.listing_status IS DISTINCT FROM OLD.listing_status) EXECUTE FUNCTION sync_store_listing_count_on_status(); EXCEPTION WHEN duplicate_object THEN null; END $$;

INSERT INTO categories (name, sector, slug, sort_order) VALUES
('Hotels & Lodging','SERVICE','hotels-lodging',1),('Food & Restaurants','SERVICE','food-restaurants',2),
('Retail','SERVICE','retail',3),('Health','SERVICE','health',4),('Beauty','SERVICE','beauty',5),
('Home Services','SERVICE','home-services',6),('Education','SERVICE','education',7),
('Professional Services','SERVICE','professional-services',8),('Entertainment','SERVICE','entertainment',9),
('Fitness','SERVICE','fitness',10),('Agriculture','SERVICE','agriculture',11),('Real Estate','SERVICE','real-estate',12)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, sub.sort_order FROM categories p
JOIN (VALUES
('hotels-lodging','Hotels','hotels',1),('hotels-lodging','Guesthouses','guesthouses',2),
('hotels-lodging','Lodges','lodges',3),('hotels-lodging','Resorts','resorts',4),('hotels-lodging','Rooms','rooms',5),
('food-restaurants','Restaurants','restaurants',1),('food-restaurants','Cafes','cafes',2),
('food-restaurants','Fast Food','fast-food',3),('food-restaurants','Bakeries','bakeries',4),
('food-restaurants','Traditional Food','traditional-food',5),('food-restaurants','Catering','catering',6),
('retail','Grocery','grocery',1),('retail','Clothing','clothing',2),('retail','Electronics','electronics',3),
('retail','Phones & Accessories','phones-accessories',4),('retail','Furniture','furniture',5),
('retail','Cosmetics','cosmetics',6),('retail','General Shops','general-shops',7),
('health','Pharmacies','pharmacies',1),('health','Clinics','clinics',2),('health','Laboratories','laboratories',3),
('health','Dental','dental',4),('health','Health Services','health-services',5),
('beauty','Barbers','barbers',1),('beauty','Hair Salons','hair-salons',2),
('beauty','Beauty Salons','beauty-salons',3),('beauty','Spa','spa',4),
('home-services','Plumbing','plumbing',1),('home-services','Electrical','electrical',2),
('home-services','Cleaning','cleaning',3),('home-services','Construction','construction',4),
('home-services','Repair','repair',5),('home-services','Maintenance','maintenance',6),
('education','Schools','schools',1),('education','Training Centers','training-centers',2),
('education','Tutors','tutors',3),('education','Courses','courses',4),
('professional-services','Accounting','accounting',1),('professional-services','Legal','legal',2),
('professional-services','Consulting','consulting',3),('professional-services','Printing','printing',4),
('professional-services','Photography','photography',5),
('entertainment','Events','events',1),('entertainment','Entertainment Centers','entertainment-centers',2),
('entertainment','Recreation','recreation',3),
('fitness','Gyms','gyms',1),('fitness','Sports','sports',2),('fitness','Fitness Centers','fitness-centers',3),
('agriculture','Agricultural Products','agricultural-products',1),('agriculture','Farm Services','farm-services',2),
('agriculture','Equipment','equipment',3),
('real-estate','Houses','houses',1),('real-estate','Land','land',2),
('real-estate','Rentals','rentals',3),('real-estate','Property Services','property-services',4)
) AS sub(parent_slug, name, slug, sort_order) ON p.slug = sub.parent_slug
ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (name, sector, slug, sort_order) VALUES
('Ride / Taxi','VEHICLE','ride-taxi',1),('Delivery Vehicle','VEHICLE','delivery-vehicle',2),
('Food Delivery','VEHICLE','food-delivery',3),('Motorcycle / Bajaj','VEHICLE','motorcycle-bajaj',4),
('Car Rental','VEHICLE','car-rental',5),('Bus','VEHICLE','bus',6),('Minibus','VEHICLE','minibus',7),
('Truck','VEHICLE','truck',8),('Freight / Cargo','VEHICLE','freight-cargo',9),
('Tour & Travel','VEHICLE','tour-travel',10),('Airport Transport','VEHICLE','airport-transport',11),
('Special Transport','VEHICLE','special-transport',12),('Ambulance / Emergency Transport','VEHICLE','ambulance-emergency',13)
ON CONFLICT (slug) DO NOTHING;

UPDATE categories SET marketplace_sector = 'ACCOMMODATION' WHERE slug = 'hotels-lodging';
UPDATE categories SET marketplace_sector = 'FOOD' WHERE slug = 'food-restaurants';
UPDATE categories SET marketplace_sector = 'RETAIL' WHERE slug = 'retail';
UPDATE categories SET marketplace_sector = 'SERVICES' WHERE slug IN ('health','beauty','home-services','education','professional-services','entertainment','fitness','agriculture','real-estate');
UPDATE categories SET marketplace_sector = 'TRANSPORT' WHERE sector = 'VEHICLE';

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'FOOD', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
('food-restaurants','Food Trucks','food-trucks','Mobile food vendors',7),
('food-restaurants','Juice Bars','juice-bars','Fresh juices and smoothies',8),
('food-restaurants','Coffee Shops','coffee-shops','Coffee and tea',9)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'RETAIL', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
('retail','Handmade Crafts','handmade-crafts','Handmade products',8),
('retail','Books & Stationery','books-stationery','Books and office supplies',9),
('retail','Sports & Outdoors','sports-outdoors','Sports equipment',10),
('retail','Baby & Kids','baby-kids','Baby products and toys',11),
('retail','Automotive Parts','automotive-parts','Car parts and accessories',12),
('retail','Garden & Home','garden-home','Garden tools and decor',13)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'ACCOMMODATION', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
('hotels-lodging','Vacation Rentals','vacation-rentals','Short-term rentals',6),
('hotels-lodging','Hostels','hostels','Budget accommodation',7),
('hotels-lodging','Apartments','apartments','Serviced apartments',8)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'SERVICES', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
('home-services','Moving & Packing','moving-packing','Relocation services',7),
('home-services','Interior Design','interior-design','Interior decoration',8),
('professional-services','IT Services','it-services','Computer repair and IT support',6),
('professional-services','Translation','translation','Translation services',7),
('professional-services','Delivery Services','delivery-services','Package delivery',8),
('health','Mental Health','mental-health','Counseling services',6),
('beauty','Tattoo & Piercing','tattoo-piercing','Tattoo studios',5),
('fitness','Yoga & Meditation','yoga-meditation','Yoga classes',4),
('entertainment','Photography Studios','photography-studios','Professional photography',4),
('education','Online Courses','online-courses','Digital learning',5)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'VEHICLE', sub.slug, 'TRANSPORT', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
('ride-taxi','Bike Taxi','bike-taxi','Motorcycle taxi',14),
('ride-taxi','Shared Rides','shared-rides','Carpooling',15),
('delivery-vehicle','Express Delivery','express-delivery','Same-day delivery',14),
('car-rental','Luxury Car Rental','luxury-car-rental','Premium vehicle rental',15),
('freight-cargo','Moving Trucks','moving-trucks','Large vehicle rental',16),
('tour-travel','Safari Tours','safari-tours','Wildlife safari packages',17)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (name, sector, slug, marketplace_sector, description, sort_order)
VALUES ('Other Services','SERVICE','other-services','OTHER','Miscellaneous services',50)
ON CONFLICT (slug) DO NOTHING;

CREATE OR REPLACE VIEW marketplace_sectors AS
SELECT marketplace_sector, COUNT(*) FILTER (WHERE parent_id IS NULL) AS top_category_count, COUNT(*) AS total_category_count
FROM categories WHERE is_active = true AND marketplace_sector IS NOT NULL GROUP BY marketplace_sector ORDER BY marketplace_sector;

COMMENT ON SCHEMA public IS '5BIRR schema — fully applied via 0022 completion migration';
