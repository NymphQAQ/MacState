#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const projectRoot = path.resolve(__dirname, "..");
const sourcePath = "Sources/MacState/Resources/Web/icons";
const outputPath = "Sources/MacState/Resources/Web/icons.css";
const repairCommand = "rtk proxy node scripts/generate-icons.js";
const sourceDirectory = path.join(projectRoot, sourcePath);
const outputFile = path.join(projectRoot, outputPath);
const args = process.argv.slice(2);

function generateStylesheet() {
  const filenames = fs.readdirSync(sourceDirectory)
    .filter((filename) => filename.endsWith(".svg"))
    .sort();

  if (filenames.length === 0) {
    throw new Error(`No SVG icons found in ${sourcePath}.`);
  }

  const rules = filenames.map((filename) => {
    const name = path.basename(filename, ".svg");
    if (!/^[a-z0-9-]+$/.test(name)) {
      throw new Error(`Invalid icon filename: ${filename}`);
    }
    const encoded = fs.readFileSync(path.join(sourceDirectory, filename)).toString("base64");
    const image = `url("data:image/svg+xml;base64,${encoded}")`;
    return `.i-${name} {\n  mask-image: ${image};\n  -webkit-mask-image: ${image};\n}`;
  });

  const header = [
    "/* Generated file; do not edit directly.",
    ` * Source: ${sourcePath}/*.svg`,
    ` * Regenerate: ${repairCommand}`,
    " */",
    ""
  ].join("\n");

  return { css: `${header}${rules.join("\n\n")}\n`, count: filenames.length };
}

function main() {
  if (args.length > 1 || (args.length === 1 && args[0] !== "--check")) {
    throw new Error("Usage: node scripts/generate-icons.js [--check]");
  }

  const { css, count } = generateStylesheet();
  if (args[0] === "--check") {
    let current;
    try {
      current = fs.readFileSync(outputFile, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (current !== css) {
      console.error(`${outputPath} is missing or out of date.`);
      console.error(`Fix: ${repairCommand}`);
      process.exitCode = 1;
      return;
    }
    console.log(`Icons CSS is current (${count} icons).`);
    return;
  }

  fs.writeFileSync(outputFile, css, "utf8");
  console.log(`Generated ${outputPath} (${count} icons).`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
