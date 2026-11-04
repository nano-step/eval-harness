// atd-budget-reporter.mjs — trusted, official StrykerJS reporter plugin (declareValuePlugin, kind Reporter).
// It enforces the per-run mutant budget BEFORE any mutant is executed: Stryker emits
// onMutationTestingPlanReady({ mutantPlans }) once the plan is final and before mutant execution. The
// hook records the decision synchronously in /out/mutation-budget.json and, when the plan exceeds the
// budget, terminates the process with exit status 86. A throw would not work: Stryker's BroadcastReporter
// swallows reporter exceptions, so the process is ended explicitly. The plugin has no model authority
// and reads only the trusted ATD_MAX_MUTANTS environment value (set by the sandbox controller).
//   exit 86 = planned mutants exceed the budget (refusal)
//   exit 87 = the budget itself is missing/invalid (fail closed)
import fs from 'node:fs';
import { PluginKind, declareValuePlugin } from '@stryker-mutator/api/plugin';

export const BUDGET_FILE = '/out/mutation-budget.json';
const HARD_MAX = 500;

function record(doc) {
  const fd = fs.openSync(BUDGET_FILE, 'w', 0o644);
  try { fs.writeSync(fd, `${JSON.stringify(doc)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

const reporter = {
  onMutationTestingPlanReady(event) {
    const raw = process.env.ATD_MAX_MUTANTS;
    const maxMutants = /^[0-9]+$/.test(raw ?? '') ? Number(raw) : NaN;
    const plans = event && Array.isArray(event.mutantPlans) ? event.mutantPlans : null;
    if (!Number.isSafeInteger(maxMutants) || maxMutants < 1 || maxMutants > HARD_MAX || plans === null) {
      record({ schema: 'atd.mutation-budget/v1', maxMutants: Number.isFinite(maxMutants) ? maxMutants : null, planned: plans === null ? null : plans.length, allowed: false, reason: 'invalid_budget' });
      process.exit(87);
    }
    // Conservative: every plan counts, including ones Stryker could settle without executing a test run.
    const planned = plans.length;
    const allowed = planned <= maxMutants;
    record({ schema: 'atd.mutation-budget/v1', maxMutants, planned, allowed });
    if (!allowed) process.exit(86);
  },
};

export const strykerPlugins = [declareValuePlugin(PluginKind.Reporter, 'atd-budget', reporter)];
