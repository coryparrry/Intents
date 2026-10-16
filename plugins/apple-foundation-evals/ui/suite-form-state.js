// Keep the supported flat suite format until the user edits an app-format suite.
export function isAppSuiteFormat(suite) {
  return ['version', 'criteria', 'scoringMode', 'modelConfiguration', 'features', 'attachments', 'judgeConfiguration', 'releasePolicy'].some(key => suite[key] !== undefined)
    || suite.cases?.some(item => item.conversation !== undefined || item.fieldAssertions !== undefined);
}

export function caseEditorDetails(test) {
  const conversation = structuredClone(test?.conversation || {});
  conversation.setupTurns ||= [];
  conversation.historyPolicy ||= 'keepAll';
  conversation.retainedTurnCount ??= 2;
  conversation.modelHistoryProjection ||= { policy: 'keepAll', retainedTurnCount: 2 };
  return { conversation, checks: structuredClone(test?.fieldAssertions || []) };
}

export function commitCaseEditorDetails(suite, test, details) {
  if (!test || !isAppSuiteFormat(suite)) return;
  test.conversation = details.conversation;
  test.fieldAssertions = details.checks;
}

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

export function normalizeSchemaOptional(field) {
  if (!field.isOptional) field.representNilExplicitlyInGeneratedContent = false;
}

export function newSchemaField(name = '') {
  return { id: crypto.randomUUID(), name, description: '', type: 'string', isOptional: false, children: [], enumValues: [], constraints: { stringPattern: '' }, referenceName: '', representNilExplicitlyInGeneratedContent: false };
}
