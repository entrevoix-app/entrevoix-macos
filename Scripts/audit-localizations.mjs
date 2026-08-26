#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const repositoryRoot = process.cwd();
const catalogPath = path.join(repositoryRoot, "Sources/Entrevoix/Resources/Localizable.xcstrings");
const requiredLocales = ["en", "fr-FR"];
const catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
const catalogKeys = Object.keys(catalog.strings).sort();
const catalogKeySet = new Set(catalogKeys);
const source = swiftFiles(path.join(repositoryRoot, "Sources"))
    .map((file) => fs.readFileSync(file, "utf8"))
    .join("\n");
const referencedKeys = referencedLocalizationKeys(source);

const missingTranslations = [];
for (const key of catalogKeys) {
    for (const locale of requiredLocales) {
        if (!hasCompleteTranslation(catalog.strings[key].localizations?.[locale])) {
            missingTranslations.push(`${key} (${locale})`);
        }
    }
}

const missingCatalogEntries = [...referencedKeys]
    .filter((key) => !catalogKeySet.has(key))
    .sort();
const unusedCatalogEntries = catalogKeys
    .filter((key) => !referencedKeys.has(key))
    .sort();

console.log(`Catalog keys: ${catalogKeys.length}`);
console.log(`Production localization references: ${referencedKeys.size}`);
console.log(`Missing translations: ${missingTranslations.length}`);
console.log(`Missing catalog entries: ${missingCatalogEntries.length}`);
console.log(`Unused catalog entries: ${unusedCatalogEntries.length}`);

report("Missing translations", missingTranslations);
report("Missing catalog entries", missingCatalogEntries);
report("Unused catalog entries", unusedCatalogEntries);

if (missingTranslations.length || missingCatalogEntries.length || unusedCatalogEntries.length) {
    process.exitCode = 1;
} else {
    console.log("LOCALIZATION AUDIT PASSED");
}

function swiftFiles(directory) {
    return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const entryPath = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            return swiftFiles(entryPath);
        }
        return entry.isFile() && entry.name.endsWith(".swift") ? [entryPath] : [];
    });
}

function referencedLocalizationKeys(contents) {
    const keys = new Set();
    const keyPatterns = [
        /\b(?:EntrevoixLocalization\.text|localized|text)\(\s*"([^"]+)"/g,
        /\bkey:\s*"([^"]+)"/g,
        /\bprefixKey:\s*"([^"]+)"/g
    ];

    for (const pattern of keyPatterns) {
        for (const match of contents.matchAll(pattern)) {
            const key = match[1];
            if (/^[a-z0-9_]+(?:\.[a-z0-9_]+)+$/.test(key)) {
                keys.add(key);
            }
        }
    }
    return keys;
}

function hasCompleteTranslation(localization) {
    const units = stringUnits(localization);
    return units.length > 0 && units.every((unit) => (
        unit.state === "translated"
            && typeof unit.value === "string"
            && unit.value.trim().length > 0
    ));
}

function stringUnits(value) {
    if (!value || typeof value !== "object") {
        return [];
    }
    if (Array.isArray(value)) {
        return value.flatMap(stringUnits);
    }
    if (value.stringUnit) {
        return [value.stringUnit];
    }
    return Object.values(value).flatMap(stringUnits);
}

function report(title, entries) {
    if (entries.length > 0) {
        console.log(`${title}:`);
        for (const entry of entries) {
            console.log(`- ${entry}`);
        }
    }
}
