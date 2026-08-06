// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {lstat} from "node:fs/promises";
import {join, parse, resolve, sep} from "node:path";

function unsafePathError() {
  const error = new Error("Buzz source read failed");
  error.code = "unsafe_source";
  return error;
}

function pathComponents(filePath) {
  const absolutePath = resolve(filePath);
  const root = parse(absolutePath).root;
  const components = [root];
  let current = root;
  for (const component of absolutePath.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, component);
    components.push(current);
  }
  return components;
}

export async function captureSafePathIdentity(filePath) {
  const components = [];
  for (const componentPath of pathComponents(filePath)) {
    const stats = await lstat(componentPath);
    if (stats.isSymbolicLink()) throw unsafePathError();
    components.push({componentPath, dev: stats.dev, ino: stats.ino, stats});
  }
  return {components, target: components.at(-1).stats};
}

export async function verifySafePathIdentity(identity) {
  let target;
  for (const component of identity.components) {
    let stats;
    try {
      stats = await lstat(component.componentPath);
    } catch {
      throw unsafePathError();
    }
    if (stats.isSymbolicLink() || stats.dev !== component.dev || stats.ino !== component.ino) {
      throw unsafePathError();
    }
    target = stats;
  }
  return target;
}
