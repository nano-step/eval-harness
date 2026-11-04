import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // `test/` holds the repository's own tests. The atd-sandbox runner mounts a generated candidate test
    // under `tests/`. The runner chooses the reporter and output file; no network and no watch mode.
    include: ["test/**/*.test.ts", "tests/**/*.test.ts"],
    watch: false,
  },
});
