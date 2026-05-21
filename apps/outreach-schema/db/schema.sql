SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: enforce_approval_match(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_approval_match() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a approvals%ROWTYPE;
BEGIN
  SELECT * INTO a FROM approvals WHERE id = NEW.approval_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'publish_job approval_id=% not found', NEW.approval_id;
  END IF;
  IF a.decision <> 'approved' THEN
    RAISE EXCEPTION 'publish_job approval_id=% has decision=%, must be approved', NEW.approval_id, a.decision;
  END IF;
  IF a.expires_at < now() THEN
    RAISE EXCEPTION 'publish_job approval_id=% expired at %', NEW.approval_id, a.expires_at;
  END IF;
  IF NEW.payload_hash <> a.approved_content_hash THEN
    RAISE EXCEPTION 'publish_job payload_hash does not match approved_content_hash';
  END IF;
  RETURN NEW;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.approvals (
    id bigint NOT NULL,
    draft_id bigint NOT NULL,
    approved_by text NOT NULL,
    decision text NOT NULL,
    edited_text text,
    approved_destination text NOT NULL,
    approved_post_type text NOT NULL,
    approved_content_hash text NOT NULL,
    approval_notes text,
    approved_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '7 days'::interval) NOT NULL,
    CONSTRAINT approvals_decision_check CHECK ((decision = ANY (ARRAY['approved'::text, 'rejected'::text, 'manual_only'::text, 'save_for_later'::text])))
);


--
-- Name: approvals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.approvals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: approvals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.approvals_id_seq OWNED BY public.approvals.id;


--
-- Name: drafts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drafts (
    id bigint NOT NULL,
    outreach_item_id bigint NOT NULL,
    variant text NOT NULL,
    model_provider text NOT NULL,
    model_name text NOT NULL,
    prompt_version text NOT NULL,
    draft_text text NOT NULL,
    suggested_destination text NOT NULL,
    suggested_post_type text NOT NULL,
    claims_to_verify jsonb DEFAULT '[]'::jsonb NOT NULL,
    risk_flags jsonb DEFAULT '[]'::jsonb NOT NULL,
    risk_score smallint DEFAULT 50 NOT NULL,
    manual_only boolean DEFAULT false NOT NULL,
    content_hash text NOT NULL,
    status text DEFAULT 'needs_human_review'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT drafts_risk_score_check CHECK (((risk_score >= 0) AND (risk_score <= 100))),
    CONSTRAINT drafts_status_check CHECK ((status = ANY (ARRAY['needs_human_review'::text, 'approved'::text, 'rejected'::text, 'expired'::text]))),
    CONSTRAINT drafts_variant_check CHECK ((variant = ANY (ARRAY['helpful_only'::text, 'founder_context'::text, 'soft_product'::text])))
);


--
-- Name: drafts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.drafts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: drafts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.drafts_id_seq OWNED BY public.drafts.id;


--
-- Name: outcomes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outcomes (
    id bigint NOT NULL,
    publish_job_id bigint,
    impressions integer,
    replies integer,
    clicks integer,
    signups integer,
    notes text,
    captured_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: outcomes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outcomes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outcomes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outcomes_id_seq OWNED BY public.outcomes.id;


--
-- Name: outreach_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outreach_items (
    id bigint NOT NULL,
    source_platform text NOT NULL,
    source_url text NOT NULL,
    source_excerpt text,
    source_author text,
    source_community text,
    topic text,
    persona text,
    intent_score smallint,
    risk_score smallint,
    status text DEFAULT 'discovered'::text NOT NULL,
    discovered_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outreach_items_intent_score_check CHECK (((intent_score >= 0) AND (intent_score <= 100))),
    CONSTRAINT outreach_items_risk_score_check CHECK (((risk_score >= 0) AND (risk_score <= 100))),
    CONSTRAINT outreach_items_source_platform_check CHECK ((source_platform = ANY (ARRAY['manual'::text, 'rss'::text, 'reddit'::text, 'x'::text, 'bluesky'::text, 'mastodon'::text, 'google_alerts'::text]))),
    CONSTRAINT outreach_items_status_check CHECK ((status = ANY (ARRAY['discovered'::text, 'drafting'::text, 'drafted'::text, 'reviewed'::text, 'published'::text, 'rejected'::text, 'archived'::text])))
);


--
-- Name: outreach_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.outreach_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: outreach_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.outreach_items_id_seq OWNED BY public.outreach_items.id;


--
-- Name: publish_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.publish_jobs (
    id bigint NOT NULL,
    approval_id bigint NOT NULL,
    destination_platform text NOT NULL,
    destination_account text NOT NULL,
    postiz_integration_id text,
    scheduled_for timestamp with time zone,
    publish_mode text NOT NULL,
    status text DEFAULT 'ready'::text NOT NULL,
    postiz_post_id text,
    published_url text,
    published_at timestamp with time zone,
    failure_reason text,
    payload_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    sent_at timestamp with time zone,
    CONSTRAINT publish_jobs_publish_mode_check CHECK ((publish_mode = ANY (ARRAY['postiz_scheduled'::text, 'postiz_immediate'::text, 'manual_required'::text]))),
    CONSTRAINT publish_jobs_status_check CHECK ((status = ANY (ARRAY['ready'::text, 'sent_to_postiz'::text, 'scheduled'::text, 'published'::text, 'manual_post_required'::text, 'failed'::text, 'expired'::text, 'abandoned'::text])))
);


--
-- Name: publish_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.publish_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: publish_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.publish_jobs_id_seq OWNED BY public.publish_jobs.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: approvals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals ALTER COLUMN id SET DEFAULT nextval('public.approvals_id_seq'::regclass);


--
-- Name: drafts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drafts ALTER COLUMN id SET DEFAULT nextval('public.drafts_id_seq'::regclass);


--
-- Name: outcomes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outcomes ALTER COLUMN id SET DEFAULT nextval('public.outcomes_id_seq'::regclass);


--
-- Name: outreach_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outreach_items ALTER COLUMN id SET DEFAULT nextval('public.outreach_items_id_seq'::regclass);


--
-- Name: publish_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publish_jobs ALTER COLUMN id SET DEFAULT nextval('public.publish_jobs_id_seq'::regclass);


--
-- Name: approvals approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals
    ADD CONSTRAINT approvals_pkey PRIMARY KEY (id);


--
-- Name: drafts drafts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drafts
    ADD CONSTRAINT drafts_pkey PRIMARY KEY (id);


--
-- Name: outcomes outcomes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outcomes
    ADD CONSTRAINT outcomes_pkey PRIMARY KEY (id);


--
-- Name: outreach_items outreach_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outreach_items
    ADD CONSTRAINT outreach_items_pkey PRIMARY KEY (id);


--
-- Name: outreach_items outreach_items_source_platform_source_url_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outreach_items
    ADD CONSTRAINT outreach_items_source_platform_source_url_key UNIQUE (source_platform, source_url);


--
-- Name: publish_jobs publish_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publish_jobs
    ADD CONSTRAINT publish_jobs_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: idx_drafts_status_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_drafts_status_created_at ON public.drafts USING btree (status, created_at);


--
-- Name: idx_outreach_items_status_discovered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outreach_items_status_discovered_at ON public.outreach_items USING btree (status, discovered_at);


--
-- Name: idx_publish_jobs_status_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_publish_jobs_status_scheduled ON public.publish_jobs USING btree (status, scheduled_for);


--
-- Name: idx_publish_jobs_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_publish_jobs_status_created ON public.publish_jobs USING btree (status, created_at);


--
-- Name: publish_jobs trg_enforce_approval_match; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_enforce_approval_match BEFORE INSERT OR UPDATE OF payload_hash, approval_id ON public.publish_jobs FOR EACH ROW EXECUTE FUNCTION public.enforce_approval_match();


--
-- Name: approvals approvals_draft_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.approvals
    ADD CONSTRAINT approvals_draft_id_fkey FOREIGN KEY (draft_id) REFERENCES public.drafts(id);


--
-- Name: drafts drafts_outreach_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drafts
    ADD CONSTRAINT drafts_outreach_item_id_fkey FOREIGN KEY (outreach_item_id) REFERENCES public.outreach_items(id);


--
-- Name: outcomes outcomes_publish_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outcomes
    ADD CONSTRAINT outcomes_publish_job_id_fkey FOREIGN KEY (publish_job_id) REFERENCES public.publish_jobs(id);


--
-- Name: publish_jobs publish_jobs_approval_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.publish_jobs
    ADD CONSTRAINT publish_jobs_approval_id_fkey FOREIGN KEY (approval_id) REFERENCES public.approvals(id);


--
-- PostgreSQL database dump complete
--


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260519120000'),
    ('20260519120100'),
    ('20260519120200'),
    ('20260519120300'),
    ('20260519120400'),
    ('20260519120500'),
    ('20260519120600'),
    ('20260520120000'),
    ('20260520120100'),
    ('20260521120000'),
    ('20260521130000');
