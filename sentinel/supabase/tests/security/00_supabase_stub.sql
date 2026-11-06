-- Minimal Supabase environment: roles, auth schema, auth.uid(), default grants.
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to public;
grant select on auth.users to anon, authenticated;  -- FK checks need it

grant usage on schema public to anon, authenticated, service_role;
-- Supabase's default: everything new in public is granted to the API roles
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- test helper: run stmt in a subtransaction, report outcome, always roll back
create function public.t(label text, stmt text, expect text) returns void
language plpgsql as $$
declare n bigint; outcome text; ok boolean;
begin
  begin
    execute stmt;
    get diagnostics n = row_count;
    outcome := 'rows=' || n;
    raise exception using errcode = 'ZZ999';
  exception
    when sqlstate 'ZZ999' then null;
    when others then outcome := 'error: ' || sqlerrm;
  end;
  ok := case expect
          when 'error' then outcome like 'error%'
          when 'ok'    then outcome like 'rows=%'
          when 'rows>0' then outcome like 'rows=%' and outcome <> 'rows=0'
          else outcome = expect end;
  raise notice '% | % | expected % | got %',
    case when ok then 'PASS' else 'FAIL' end, label, expect, outcome;
end $$;
grant execute on function public.t(text, text, text) to public;
