-- layer schemas
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dwh;
CREATE SCHEMA IF NOT EXISTS dm;

-- staging layer
CREATE TABLE IF NOT EXISTS stg.raw_partner_loan_disbursement (
    partner_loan_id     VARCHAR(64),
    cif_number          VARCHAR(32),
    national_id         VARCHAR(32),
    full_name           VARCHAR(128),
    channel_name        VARCHAR(64),
    disbursement_amt    NUMERIC(18, 2),
    interest_rate       NUMERIC(6, 4),
    tenor               INTEGER,
    disbursement_date   DATE,
    rail                VARCHAR(32),
    ingested_at         TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stg.raw_partner_loan_repayment (
    payment_ref_num     VARCHAR(64),
    partner_loan_id     VARCHAR(64),
    payment_amt         NUMERIC(18, 2),
    payment_channel     VARCHAR(32),
    payment_timestamp   TIMESTAMP WITH TIME ZONE,
    ingested_at         TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stg.quarantine_bad_records (
    quarantine_id       BIGSERIAL PRIMARY KEY,
    source_table        VARCHAR(64) NOT NULL,
    raw_payload_json    JSONB NOT NULL,
    failure_reason      VARCHAR(255) NOT NULL,
    quarantined_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- warehouse layer
CREATE TABLE IF NOT EXISTS dwh.dim_delinquency_bucket (
    bucket_sk           INT PRIMARY KEY,
    dpd_min             INT NOT NULL,
    dpd_max             INT NOT NULL,
    regulatory_kol      VARCHAR(32) NOT NULL,
    ifrs9_stage         VARCHAR(16) NOT NULL,
    base_provision_rate NUMERIC(6, 4) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.dim_chart_of_accounts (
    coa_sk              INT PRIMARY KEY,
    gl_account_number   VARCHAR(32) UNIQUE NOT NULL,
    gl_account_name     VARCHAR(128) NOT NULL,
    gl_account_type     VARCHAR(16) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.dim_borrower (
    borrower_sk         BIGSERIAL PRIMARY KEY,
    cif_number          VARCHAR(32) NOT NULL,
    national_id_hash    VARCHAR(64) NOT NULL,
    masked_full_name    VARCHAR(128) NOT NULL,
    employment_sector   VARCHAR(64),
    verified_monthly_income NUMERIC(18, 2),
    kyc_risk_level      VARCHAR(16) NOT NULL,
    is_pep_flag         BOOLEAN DEFAULT FALSE,
    row_effective_date  TIMESTAMP WITH TIME ZONE NOT NULL,
    row_expiration_date TIMESTAMP WITH TIME ZONE DEFAULT '9999-12-31 23:59:59+00'::timestamptz,
    is_current          BOOLEAN DEFAULT TRUE,
    UNIQUE (cif_number, row_effective_date)
);

CREATE TABLE IF NOT EXISTS dwh.dim_partner_channel (
    partner_sk          SERIAL PRIMARY KEY,
    partner_code        VARCHAR(32) UNIQUE NOT NULL,
    partnership_model   VARCHAR(32) NOT NULL,
    bank_risk_share_pct NUMERIC(5, 4) NOT NULL,
    partner_risk_share_pct NUMERIC(5, 4) NOT NULL,
    escrow_account_num  VARCHAR(32) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.dim_credit_underwriting (
    underwriting_sk     BIGSERIAL PRIMARY KEY,
    application_id      VARCHAR(64) UNIQUE NOT NULL,
    credit_bureau_score INT,
    internal_ml_score   INT NOT NULL,
    final_risk_grade    VARCHAR(8) NOT NULL,
    dscr_ratio          NUMERIC(6, 4),
    underwriting_decision VARCHAR(16) NOT NULL,
    model_version       VARCHAR(16) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.dim_loan_facility (
    facility_sk         BIGSERIAL PRIMARY KEY,
    loan_contract_num   VARCHAR(64) UNIQUE NOT NULL,
    borrower_sk         BIGINT NOT NULL REFERENCES dwh.dim_borrower(borrower_sk),
    partner_sk          INT NOT NULL REFERENCES dwh.dim_partner_channel(partner_sk),
    underwriting_sk     BIGINT NOT NULL REFERENCES dwh.dim_credit_underwriting(underwriting_sk),
    loan_product_type   VARCHAR(32) NOT NULL,
    interest_calculation_method VARCHAR(16) NOT NULL,
    approved_limit_amt  NUMERIC(18, 2) NOT NULL,
    annual_interest_rate NUMERIC(6, 4) NOT NULL,
    tenor_months        INT NOT NULL,
    is_restructured     BOOLEAN DEFAULT FALSE,
    disbursement_date   DATE NOT NULL,
    maturity_date       DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.fact_loan_disbursement (
    disbursement_sk     BIGSERIAL PRIMARY KEY,
    disbursement_id     VARCHAR(64) UNIQUE NOT NULL,
    facility_sk         BIGINT NOT NULL REFERENCES dwh.dim_loan_facility(facility_sk),
    coa_sk              INT NOT NULL REFERENCES dwh.dim_chart_of_accounts(coa_sk),
    disbursement_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    gross_disbursed_amt NUMERIC(18, 2) NOT NULL,
    admin_fee_deducted  NUMERIC(18, 2) DEFAULT 0.00,
    net_disbursed_amt   NUMERIC(18, 2) NOT NULL,
    disbursement_rail   VARCHAR(32) NOT NULL,
    etl_batch_id        VARCHAR(64) NOT NULL,
    etl_source_system   VARCHAR(32) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.fact_loan_repayment (
    repayment_sk        BIGSERIAL PRIMARY KEY,
    payment_reference_num VARCHAR(64) UNIQUE NOT NULL,
    facility_sk         BIGINT NOT NULL REFERENCES dwh.dim_loan_facility(facility_sk),
    coa_sk              INT NOT NULL REFERENCES dwh.dim_chart_of_accounts(coa_sk),
    payment_timestamp   TIMESTAMP WITH TIME ZONE NOT NULL,
    posting_date        DATE NOT NULL,
    total_paid_amt      NUMERIC(18, 2) NOT NULL,
    allocated_late_fee_amt  NUMERIC(18, 2) NOT NULL DEFAULT 0.00,
    allocated_interest_amt  NUMERIC(18, 2) NOT NULL DEFAULT 0.00,
    allocated_principal_amt NUMERIC(18, 2) NOT NULL DEFAULT 0.00,
    overpayment_refund_amt  NUMERIC(18, 2) NOT NULL DEFAULT 0.00,
    payment_channel     VARCHAR(32) NOT NULL,
    etl_batch_id        VARCHAR(64) NOT NULL,
    etl_source_system   VARCHAR(32) NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.fact_loan_daily_snapshot (
    snapshot_date       DATE NOT NULL,
    facility_sk         BIGINT NOT NULL REFERENCES dwh.dim_loan_facility(facility_sk),
    bucket_sk           INT NOT NULL REFERENCES dwh.dim_delinquency_bucket(bucket_sk),
    os_principal_amt    NUMERIC(18, 2) NOT NULL,
    os_interest_amt     NUMERIC(18, 2) NOT NULL,
    os_late_fee_amt     NUMERIC(18, 2) NOT NULL,
    total_exposure_amt  NUMERIC(18, 2) NOT NULL,
    current_dpd         INT NOT NULL DEFAULT 0,
    ecl_reserve_amt     NUMERIC(18, 2) NOT NULL,
    bank_net_risk_exposure NUMERIC(18, 2) NOT NULL,
    is_write_off        BOOLEAN DEFAULT FALSE,
    write_off_amt       NUMERIC(18, 2) DEFAULT 0.00,
    etl_batch_id        VARCHAR(64) NOT NULL,
    etl_loaded_at       TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (snapshot_date, facility_sk)
);