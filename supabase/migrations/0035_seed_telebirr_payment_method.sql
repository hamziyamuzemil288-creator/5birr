-- 0035_seed_telebirr_payment_method.sql
--
-- Seeds the Telebirr manual-payment method shown on the provider wallet
-- recharge screen (lib/features/wallet/recharge_screen.dart). Without a row
-- in payment_methods the screen shows "No payment methods available" and
-- providers cannot submit recharge requests.
--
-- The account details below live in the payment_methods table: admins edit
-- them in Admin → Payment Methods (/admin/payment-methods), so the Telebirr
-- account can be updated later without a code deploy.
--
-- Idempotent: does nothing if any Telebirr method already exists.

insert into payment_methods (name, account_name, account_number, instructions, is_active, sort_order)
select
  'Telebirr',
  'Aliob Business',
  '0917686990',
  'Send the recharge amount to the Telebirr account above via the Telebirr app or USSD, then submit this form with the transaction reference number and a payment screenshot. Your wallet will be credited after admin verification.',
  true,
  0
where not exists (
  select 1 from payment_methods where lower(name) = 'telebirr'
);
