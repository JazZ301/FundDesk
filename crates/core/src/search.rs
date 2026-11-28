use crate::model::Fund;

pub const RESULT_LIMIT: usize = 35;

pub fn catalog_results(catalog: &[Fund], keyword: &str, limit: usize) -> Vec<Fund> {
    let normalized = keyword
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    if normalized.is_empty() || limit == 0 {
        return Vec::new();
    }
    if Fund::valid_code(&normalized) {
        return catalog
            .iter()
            .find(|fund| fund.code == normalized)
            .cloned()
            .into_iter()
            .collect();
    }
    catalog
        .iter()
        .filter(|fund| fund_matches(fund, &normalized))
        .take(limit)
        .cloned()
        .collect()
}

pub fn merge(watched: &[Fund], other: &[Fund], limit: usize) -> Vec<Fund> {
    if limit == 0 {
        return Vec::new();
    }
    let mut seen = std::collections::HashSet::new();
    let mut results = Vec::new();
    for fund in watched.iter().chain(other) {
        if !seen.insert(fund.code.clone()) {
            continue;
        }
        results.push(fund.clone());
        if results.len() == limit {
            break;
        }
    }
    results
}

pub fn fund_matches(fund: &Fund, keyword: &str) -> bool {
    let normalized = keyword
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    if normalized.is_empty() {
        return true;
    }
    let name = fund
        .name
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    fund.code.starts_with(&normalized)
        || name.contains(&normalized)
        || fund.initials.to_uppercase().starts_with(&normalized)
        || fund.pinyin.to_uppercase().contains(&normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fund(code: &str, name: &str, initials: &str, pinyin: &str) -> Fund {
        Fund {
            code: code.to_string(),
            name: name.to_string(),
            kind: String::new(),
            initials: initials.to_string(),
            pinyin: pinyin.to_string(),
        }
    }

    #[test]
    fn matches_code_prefix_name_initials_and_pinyin() {
        let catalog = vec![
            fund("007339", "易方达沪深300ETF联接C", "YFD", "yifangda"),
            fund("050025", "博时标普500ETF联接A", "BS", "boshi"),
        ];
        assert_eq!(catalog_results(&catalog, "0073", 35)[0].code, "007339");
        assert_eq!(catalog_results(&catalog, "沪深 300", 35)[0].code, "007339");
        assert_eq!(catalog_results(&catalog, "yfd", 35)[0].code, "007339");
        assert_eq!(catalog_results(&catalog, "boshi", 35)[0].code, "050025");
        assert_eq!(catalog_results(&catalog, "050025", 35).len(), 1);
        assert!(catalog_results(&catalog, "05002", 35).len() == 1);
    }
}
