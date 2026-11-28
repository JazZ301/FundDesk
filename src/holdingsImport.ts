export const holdingsHeader = "基金代码\t基金名称\t持有份额\t每份成本";

export type HoldingsImportRow = {
  code: string;
  name?: string;
  shares?: string;
  cost?: string;
};

export function parseHoldingsImport(input: string): { rows: HoldingsImportRow[]; errors: string[] } {
  if (new TextEncoder().encode(input).length > 8 * 1024 * 1024) {
    return { rows: [], errors: ["持仓文本超过 8 MB。"] };
  }
  const lines = input.replace(/^\uFEFF/, "").split(/\r\n|\n|\r/)
    .map((text, index) => ({ text, number: index + 1 }))
    .filter(({ text }) => text.trim());
  if (/^```(?:tsv|txt|text)?\s*$/i.test(lines[0]?.text.trim() ?? "") &&
      lines.at(-1)?.text.trim() === "```") {
    lines.shift();
    lines.pop();
  }
  if (lines.shift()?.text.trim() !== holdingsHeader) {
    return { rows: [], errors: ["表头不匹配。请使用模板中的四列，并用 Tab 键分隔各列。"] };
  }

  const rows: HoldingsImportRow[] = [];
  const errors: string[] = [];
  const seen = new Map<string, number>();
  for (const { text, number } of lines) {
    const fields = text.split("\t").map((field) => field.trim());
    if (fields.length !== 4) {
      errors.push(`第 ${number} 行应有四列，请检查 Tab 分隔符。`);
      continue;
    }
    const [code, name, sharesText, costText] = fields;
    if (!/^\d{6}$/.test(code)) {
      errors.push(`第 ${number} 行基金代码须为六位数字，含前导零。`);
      continue;
    }
    const previous = seen.get(code);
    if (previous !== undefined) {
      errors.push(`第 ${number} 行与第 ${previous} 行的基金代码 ${code} 重复，请核实后合并为一行。`);
      continue;
    }
    seen.set(code, number);

    const shares = optionalValue(sharesText);
    const cost = optionalValue(costText);
    if ((shares !== undefined && !validDecimal(shares)) ||
        (cost !== undefined && (!validDecimal(cost) || !/[1-9]/.test(cost)))) {
      errors.push(`第 ${number} 行份额须为非负数字，每份成本须大于 0。缺失请填“-”。`);
      continue;
    }
    if (shares === undefined && cost === undefined) {
      errors.push(`第 ${number} 行缺少份额和每份成本，请补充至少一项。`);
      continue;
    }
    rows.push({ code, name: optionalValue(name), shares, cost });
  }
  if (!rows.length && !errors.length) errors.push("请在表头下方填入至少一只基金。");
  return { rows, errors };
}

function optionalValue(text: string): string | undefined {
  return text === "" || text === "-" ? undefined : text;
}

function validDecimal(text: string): boolean {
  return /^\d+(?:\.\d+)?$/.test(text) && text.replace(".", "").length <= 28;
}
