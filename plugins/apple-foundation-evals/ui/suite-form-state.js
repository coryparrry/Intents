/** Detects application-format features so supported flat suites retain their format until the user edits application settings. */
export function isAppSuiteFormat(suite) {
  return ['version', 'criteria', 'scoringMode', 'modelConfiguration', 'features', 'attachments', 'judgeConfiguration', 'releasePolicy'].some(key => suite[key] !== undefined)
    || suite.cases?.some(item => item.conversation !== undefined || item.fieldAssertions !== undefined);
}

/** Clones conversation and field-check details with editor defaults so opening a case need not mutate its format. */
export function caseEditorDetails(test) {
  const conversation = structuredClone(test?.conversation || {});
  conversation.setupTurns ||= [];
  conversation.historyPolicy ||= 'keepAll';
  conversation.retainedTurnCount ??= 2;
  conversation.modelHistoryProjection ||= { policy: 'keepAll', retainedTurnCount: 2 };
  return { conversation, checks: structuredClone(test?.fieldAssertions || []) };
}

/** Commits edited conversation and field checks only when a case and application-format suite are present. */
export function commitCaseEditorDetails(suite, test, details) {
  if (!test || !isAppSuiteFormat(suite)) return;
  test.conversation = details.conversation;
  test.fieldAssertions = details.checks;
}

/** Resets type-specific schema state and seeds array, union or enumeration content for the newly selected type. */
export function normalizeSchemaType(field) {
  field.children = [];
  field.enumValues = [];
  field.constraints = { stringPattern: '' };
  field.referenceName = '';
  field.representNilExplicitlyInGeneratedContent = false;
  if (field.type === 'array') field.children = [newSchemaField('item')];
  if (field.type === 'union') field.children = [newSchemaField('first'), newSchemaField('second')];
  if (field.type === 'enumeration') field.enumValues = [{ id: crypto.randomUUID(), value: 'value' }];
}

/** Clears explicit-nil representation when a schema field is no longer optional. */
export function normalizeSchemaOptional(field) {
  if (!field.isOptional) field.representNilExplicitlyInGeneratedContent = false;
}

/** Creates an identified string schema field with empty nested, enumeration, constraint and reference settings. */
export function newSchemaField(name = '') {
  return { id: crypto.randomUUID(), name, description: '', type: 'string', isOptional: false, children: [], enumValues: [], constraints: { stringPattern: '' }, referenceName: '', representNilExplicitlyInGeneratedContent: false };
}
