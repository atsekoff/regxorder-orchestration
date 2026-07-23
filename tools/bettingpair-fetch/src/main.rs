use std::{env, process::ExitCode, time::Duration};

const DEFAULT_URL: &str = "https://portal.bettingpair.com/api/clicks/schedule";

struct Args {
    from: String,
    to: String,
    url: String,
}

fn required_env(name: &str) -> Result<String, String> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("environment variable {name} is not set"))
}

fn next_value(arguments: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    arguments
        .next()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn parse_args() -> Result<Args, String> {
    let mut arguments = env::args().skip(1);
    let mut from = None;
    let mut to = None;
    let mut url = DEFAULT_URL.to_owned();

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--from" => from = Some(next_value(&mut arguments, "--from")?),
            "--to" => to = Some(next_value(&mut arguments, "--to")?),
            "--url" => url = next_value(&mut arguments, "--url")?,
            "--help" | "-h" => {
                return Err(
                    "usage: bettingpair-fetch --from YYYY-MM-DD --to YYYY-MM-DD [--url URL]".into(),
                );
            }
            _ => return Err(format!("unknown argument: {argument}")),
        }
    }

    Ok(Args {
        from: from.ok_or("--from is required")?,
        to: to.ok_or("--to is required")?,
        url,
    })
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let api_key = required_env("BETTINGPAIR_API_KEY")?;
    let cloudflare_id = required_env("BETTINGPAIR_CLOUDFLARE_ID")?;
    let cloudflare_secret = required_env("BETTINGPAIR_CLOUDFLARE_SECRET")?;

    let client = reqwest::blocking::Client::builder()
        .min_tls_version(reqwest::tls::Version::TLS_1_3)
        .connect_timeout(Duration::from_secs(30))
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|error| format!("failed to build TLS client: {error}"))?;

    let response = client
        .get(&args.url)
        .query(&[("from", args.from), ("to", args.to)])
        .header("x-ads-token", api_key)
        .header("CF-Access-Client-Id", cloudflare_id)
        .header("CF-Access-Client-Secret", cloudflare_secret)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .map_err(|error| format!("request failed: {error}"))?;

    let status = response.status();
    let body = response
        .text()
        .map_err(|error| format!("failed to read response: {error}"))?;

    if !status.is_success() {
        return Err(format!("HTTP {status}: {body}"));
    }

    println!("{body}");
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("bettingpair-fetch: {error}");
            ExitCode::FAILURE
        }
    }
}
