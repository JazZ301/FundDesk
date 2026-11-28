use crate::model::{Fund, FundGroup, Holding};
use encoding_rs::{UTF_16BE, UTF_16LE};
use rust_decimal::Decimal;
use std::collections::HashMap;
use std::str::FromStr;

const HEADER: [&str; 6] = [
    "基金代码",
    "基金名称",
    "基金类型",
    "持有份额",
    "单位成本",
    "所属分类",
];

pub fn export(holdings: &[Holding]) -> String {
    let mut rows: Vec<Vec<String>> = vec![HEADER.iter().map(|value| value.to_string()).collect()];
    for holding in holdings {
        let mut categories = vec!["全部自选".to_string()];
        if holding.shares.unwrap_or_default() > Decimal::ZERO {
            categories.push("我的持仓".to_string());
        }
        categories.extend(
            holding
                .group_values()
                .iter()
                .map(|group| group.title().to_string()),
        );
        rows.push(vec![
            holding.id().to_string(),
            spreadsheet_text(&holding.fund.name),
            spreadsheet_text(&holding.fund.kind),
            entry(holding.shares),
            entry(holding.cost_per_share),
            categories.join("|"),
        ]);
    }
    let body = rows
        .iter()
        .map(|row| {
            row.iter()
                .map(|field| escape(field))
                .collect::<Vec<_>>()
                .join(",")
        })
        .collect::<Vec<_>>()
        .join("\r\n");
    format!("\u{FEFF}{body}\r\n")
}

pub fn parse(
    data: &[u8],
    catalog: &HashMap<String, Fund>,
) -> Result<(Vec<Holding>, usize), &'static str> {
    let text = if data.starts_with(&[0xFF, 0xFE]) {
        let (text, _, _) = UTF_16LE.decode(data);
        text.into_owned()
    } else if data.starts_with(&[0xFE, 0xFF]) {
        let (text, _, _) = UTF_16BE.decode(data);
        text.into_owned()
    } else {
        String::from_utf8(data.to_vec()).map_err(|_| "无法识别 CSV 编码")?
    };
    let rows = split_rows(&text).ok_or("CSV 引号未闭合")?;
    let labels = rows.first().ok_or("CSV 缺少表头")?;
    let header = labels
        .iter()
        .map(|label| label.trim().replace('\u{FEFF}', "").to_lowercase())
        .collect::<Vec<_>>();
    let index = |options: &[&str]| -> Option<usize> {
        header
            .iter()
            .position(|value| options.iter().any(|option| option.to_lowercase() == *value))
    };
    let code_index = index(&["基金代码", "代码", "fundcode", "code"]).ok_or("缺少基金代码列")?;
    let name_index = index(&["基金名称", "名称", "name"]);
    let kind_index = index(&["基金类型", "类型", "kind"]);
    let shares_index = index(&["持有份额", "持仓份额", "份额", "shares", "num"]);
    let cost_index = index(&["单位成本", "成本价", "持仓成本", "cost", "costpershare"]);
    let categories_index = index(&["所属分类"]);

    let mut invalid = 0;
    let mut holdings = Vec::new();
    for row in rows.iter().skip(1) {
        let field = |column: Option<usize>| -> String {
            column
                .and_then(|column| row.get(column))
                .map(|value| value.trim().to_string())
                .unwrap_or_default()
        };
        let candidate = field(Some(code_index));
        if candidate.is_empty()
            || candidate.len() > 6
            || !candidate.bytes().all(|byte| byte.is_ascii_digit())
        {
            invalid += 1;
            continue;
        }
        let code = format!("{candidate:0>6}");
        let quantity_text = field(shares_index);
        let cost_text = field(cost_index);
        let quantity = decimal(&quantity_text);
        let cost = decimal(&cost_text);
        if (!quantity_text.is_empty()
            && !quantity
                .map(|value| value >= Decimal::ZERO)
                .unwrap_or(false))
            || (!cost_text.is_empty() && !cost.map(|value| value >= Decimal::ZERO).unwrap_or(false))
        {
            invalid += 1;
            continue;
        }
        let fund = catalog.get(&code).cloned().unwrap_or_else(|| {
            let name = field(name_index);
            Fund {
                code: code.clone(),
                name: if name.is_empty() { code.clone() } else { name },
                kind: field(kind_index),
                initials: String::new(),
                pinyin: String::new(),
            }
        });
        let mut holding = Holding {
            fund,
            shares: quantity,
            cost_per_share: cost.filter(|value| *value > Decimal::ZERO),
            groups: None,
        };
        for category in field(categories_index).split('|') {
            let title = category.trim();
            if let Some(group) = [FundGroup::Macd, FundGroup::Red]
                .into_iter()
                .find(|group| group.title() == title)
            {
                let mut groups = holding.groups.take().unwrap_or_default();
                if !groups.contains(&group) {
                    groups.push(group);
                }
                holding.groups = Some(groups);
            }
        }
        holdings.push(holding);
    }
    Ok((holdings, invalid))
}

/// Mirrors Swift's `decimal(_:)`: optional sign, ASCII digits, at most one dot.
pub fn decimal(value: &str) -> Option<Decimal> {
    let text = value.trim();
    if text.is_empty() {
        return None;
    }
    let body = text
        .strip_prefix('+')
        .or_else(|| text.strip_prefix('-'))
        .unwrap_or(text);
    if body.is_empty() {
        return None;
    }
    let mut dots = 0;
    let mut digits = 0;
    for character in body.chars() {
        match character {
            '.' => dots += 1,
            '0'..='9' => digits += 1,
            _ => return None,
        }
    }
    if dots > 1 || digits == 0 {
        return None;
    }
    Decimal::from_str(text).ok()
}

fn split_rows(text: &str) -> Option<Vec<Vec<String>>> {
    let mut result = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut characters = text.trim_start_matches('\u{FEFF}').chars().peekable();
    while let Some(current) = characters.next() {
        if current == '"' && quoted && characters.peek() == Some(&'"') {
            field.push('"');
            characters.next();
        } else if current == '"' && (quoted || field.is_empty()) {
            quoted = !quoted;
        } else if !quoted && current == ',' {
            row.push(field.clone());
            field.clear();
        } else if !quoted && (current == '\r' || current == '\n') {
            if current == '\r' && characters.peek() == Some(&'\n') {
                characters.next();
            }
            row.push(field.clone());
            if row.iter().any(|value| !value.is_empty()) {
                result.push(row.clone());
            }
            row.clear();
            field.clear();
        } else {
            field.push(current);
        }
    }
    if quoted {
        return None;
    }
    row.push(field);
    if row.iter().any(|value| !value.is_empty()) {
        result.push(row);
    }
    Some(result)
}

fn entry(value: Option<Decimal>) -> String {
    value
        .map(|value| {
            let mut value = value;
            value.normalize_assign();
            value.to_string()
        })
        .unwrap_or_default()
}

fn escape(field: &str) -> String {
    format!("\"{}\"", field.replace('"', "\"\""))
}

fn spreadsheet_text(field: &str) -> String {
    match field.trim().chars().next() {
        Some('=') | Some('+') | Some('-') | Some('@') => format!("'{field}"),
        _ => field.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn holding(code: &str, name: &str, shares: Option<&str>, cost: Option<&str>) -> Holding {
        Holding {
            fund: Fund {
                code: code.to_string(),
                name: name.to_string(),
                kind: "指数型".to_string(),
                initials: String::new(),
                pinyin: String::new(),
            },
            shares: shares.and_then(|value| Decimal::from_str(value).ok()),
            cost_per_share: cost.and_then(|value| Decimal::from_str(value).ok()),
            groups: Some(vec![FundGroup::Macd]),
        }
    }

    #[test]
    fn exports_bom_crlf_and_categories() {
        let text = export(&[holding("007339", "易方达", Some("10000"), Some("1.5"))]);
        assert!(text.starts_with('\u{FEFF}'));
        assert!(text.ends_with("\r\n"));
        assert!(text.contains("\"全部自选|我的持仓|MACD 观察\""));
        assert!(text.contains("\"10000\""));
        assert!(text.contains("\"1.5\""));
    }

    #[test]
    fn parses_quoted_rows_and_restores_groups() {
        let text = "\u{FEFF}\"基金代码\",\"基金名称\",\"持有份额\",\"单位成本\",\"所属分类\"\r\n\"7339\",\"易方达, 沪深300\",\"10000\",\"1.5\",\"全部自选|红利观察\"\r\n";
        let (holdings, invalid) = parse(text.as_bytes(), &HashMap::new()).unwrap();
        assert_eq!(invalid, 0);
        assert_eq!(holdings.len(), 1);
        assert_eq!(holdings[0].id(), "007339");
        assert_eq!(holdings[0].fund.name, "易方达, 沪深300");
        assert_eq!(holdings[0].group_values(), &[FundGroup::Red]);
    }

    #[test]
    fn rejects_bad_rows_but_keeps_good_ones() {
        let text = "基金代码,持有份额\nabc,100\n1234567,1\n007339,-1\n050025,10\n";
        let (holdings, invalid) = parse(text.as_bytes(), &HashMap::new()).unwrap();
        assert_eq!(invalid, 3);
        assert_eq!(holdings.len(), 1);
        assert_eq!(holdings[0].id(), "050025");
    }
}
