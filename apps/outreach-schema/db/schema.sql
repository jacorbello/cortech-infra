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

SET default_tablespace = '';

SET default_table_access_method = heap;

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
    CONSTRAINT outreach_items_status_check CHECK ((status = ANY (ARRAY['discovered'::text, 'drafting'::text, 'drafted'::text, 'reviewed'::text, 'rejected'::text, 'archived'::text])))
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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: outreach_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outreach_items ALTER COLUMN id SET DEFAULT nextval('public.outreach_items_id_seq'::regclass);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: idx_outreach_items_status_discovered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_outreach_items_status_discovered_at ON public.outreach_items USING btree (status, discovered_at);


--
-- PostgreSQL database dump complete
--


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260519120000');
