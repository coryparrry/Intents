import { isAppSuiteFormat } from './suite-form-state.js';
import { APP_SCORING, appSelect, appToggle, appNumber, appDisclosure, appSection, appSchemaEditor } from './native-suite.js';

export const APP_SETUP_PAGES = [
  ['instructions','Instructions','Prompt & shared context','instructions'],['scoring','Scoring','What a good answer means','file'],
  ['model','Model','Provider & generation','cpu'],['tools','Tools','Functions the model can call','tools'],
  ['output','Structured output','Response shape & fields','schema'],['profile','Session profile','Instructions between turns','profile'],
  ['performance','Performance','Streaming & prewarming','clock']
];
function appModelDefaults(draft) {
  return draft.modelConfiguration ||= { provider:'onDevice', reasoningLevel:'automatic', samplingMode:'automatic', temperatureEnabled:false, temperature:draft.temperature ?? .7, seedEnabled:false, seed:42, topK:40, probabilityThreshold:.9, maximumResponseTokens:draft.maxTokens || 1024, referenceMode:'inline', contextPolicy:'fitReferences', maximumToolCalls:2, customization:{ saveFullTranscript:true } };
}
function appFeatureDefaults(draft) { return draft.features ||= { tools:[], outputFields:[], outputSchemaDefinitions:[], profile:{enabled:false}, prewarm:false, streamResponse:false }; }
function appSamplingControls(ctx, config, prefix = '') {
  const result = ctx.node('div',null,'form-stack'), key = name => prefix ? `${prefix}${name[0].toUpperCase()}${name.slice(1)}` : name;
  result.append(appSelect(ctx,'Sampling',config,key('samplingMode'),[['automatic','Automatic'],['greedy','Greedy'],['topK','Top-K'],['probability','Random · probability']],ctx.renderMain));
  if (config[key('samplingMode')] === 'topK') result.append(appNumber(ctx,'Top-K',config,key('topK'),1,1000));
  if (config[key('samplingMode')] === 'probability') result.append(appNumber(ctx,'Probability threshold',config,key('probabilityThreshold'),.01,1,.01));
  result.append(appToggle(ctx,'Set temperature',config,key('temperatureEnabled'),ctx.renderMain));
  if (config[key('temperatureEnabled')]) result.append(appNumber(ctx,'Temperature',config,key('temperature'),0,1,.05));
  result.append(appToggle(ctx,'Use a fixed seed',config,key('seedEnabled'),ctx.renderMain));
  if (config[key('seedEnabled')]) result.append(appNumber(ctx,'Seed',config,key('seed'),0,Number.MAX_SAFE_INTEGER));
  return result;
}
function appReferenceSection(ctx) {
  const draft = ctx.state.draft, contents = ctx.node('div',null,'disclosure-body'), references = draft.attachments ||= [];
  for (const attachment of references) {
    const row = ctx.node('div',null,'reference-row'), copy = ctx.node('div'); copy.append(ctx.node('strong',attachment.name),ctx.node('small',`${attachment.kind || 'text'} · ${attachment.byteCount ?? attachment.text?.length ?? 0} bytes`));
    row.append(ctx.icon('file'),copy,ctx.button('Remove',() => { references.splice(references.indexOf(attachment),1); ctx.changed(); ctx.renderMain(); },'quiet danger')); contents.append(row);
  }
  if (!references.length) contents.append(ctx.node('p','No shared reference files.','hint'));
  contents.append(ctx.button('Add reference files…',ctx.addReferences,'secondary'));
  return appDisclosure(ctx,'Reference files','Optional · Add documents or images shared by every case',contents,'references');
}
function appScoringSection(ctx) {
  const draft = ctx.state.draft;
  const scoringMode = draft.scoringMode || 'review';
  const descriptions = { modelJudge:'Use AI for free-form requirements and exact: "text" for deterministic exact-output requirements. Every requirement must score at least 3 to pass.', exactMatch:'Pass only when the complete response equals the expected response after trimming outer whitespace.', containsExpected:'Pass when the response contains the required literal text, ignoring case and accents.', review:'Collect responses without a score unless deterministic JSON field checks assign pass or fail.' };
  const controls = [appSelect(ctx,'Scoring mode',draft,'scoringMode',Object.entries(APP_SCORING),ctx.renderMain),ctx.node('p',descriptions[scoringMode],'hint')];
  if (draft.scoringMode === 'modelJudge') controls.push(ctx.field('Requirements',draft.criteria || '',value => draft.criteria=value,true,'rubric-editor'));
  const section = appSection(ctx,'Scoring','Define what a good answer means for every case.',controls,'file');
  return section;
}
function appReleaseSection(ctx) {
  const draft = ctx.state.draft, policy = draft.releasePolicy ||= {required:false,criticalCaseIDs:[],maximumErrorCount:0,requireApprovedBaseline:false,maximumPassRateRegression:0}, contents = ctx.node('div',null,'disclosure-body');
  contents.append(appToggle(ctx,'Require release checks',policy,'required'),appNumber(ctx,'Maximum errors',policy,'maximumErrorCount',0,100),appNumber(ctx,'Maximum average latency (ms)',policy,'maximumAverageLatencyMilliseconds',0,3600000,1,true),appToggle(ctx,'Require an approved baseline',policy,'requireApprovedBaseline'),appNumber(ctx,'Maximum pass-rate regression',policy,'maximumPassRateRegression',0,1,.01));
  contents.append(ctx.node('h3','Critical cases'));
  for (const test of draft.cases) {
    const selection = {selected:policy.criticalCaseIDs.includes(test.id)}, control = appToggle({...ctx,changed:() => { policy.criticalCaseIDs = selection.selected ? [...new Set([...policy.criticalCaseIDs,test.id])] : policy.criticalCaseIDs.filter(id => id !== test.id); ctx.changed(); }},test.name || test.id,selection,'selected'); contents.append(control);
  }
  return appDisclosure(ctx,'Release requirements','Pass thresholds, baseline and latency limits',contents,'release-policy');
}
function appToolsSection(ctx) {
  const features = appFeatureDefaults(ctx.state.draft), model = appModelDefaults(ctx.state.draft), settings = model.customization ||= {saveFullTranscript:true}; features.tools ||= [];
  const controls = [appSelect(ctx,'Tool calling',settings,'toolCalling',[['automatic','Automatic'],['allowed','Allowed'],['required','Required'],['disallowed','Disallowed']]),appNumber(ctx,'Maximum tool calls',model,'maximumToolCalls',1,4)];
  const section = appSection(ctx,'Custom tools','Give the model functions with typed arguments and recorded outputs.',controls,'tools');
  const list = ctx.node('div',null,'tool-list');
  for (const tool of features.tools) {
    tool.parameters ||= []; tool.schemaDefinitions ||= [];
    const body = ctx.node('div',null,'disclosure-body'); body.append(ctx.field('Tool name',tool.name,value => tool.name=value),ctx.field('Description',tool.description,value => tool.description=value,true,'compact-editor'),appSelect(ctx,'Execution',tool,'mode',[['fixture','Fixture response'],['localHTTP','Local HTTP endpoint']],ctx.renderMain));
    if (tool.mode === 'localHTTP') body.append(ctx.field('Endpoint',tool.endpoint || '',value => tool.endpoint=value),ctx.node('p','Use a local http://127.0.0.1 endpoint. Arguments and returned output are recorded in the trace.','hint'));
    else body.append(ctx.field('Fixture response',tool.fixtureResponse || '',value => tool.fixtureResponse=value,true,'compact-editor'));
    body.append(ctx.node('h3','Arguments'),appSchemaEditor(ctx,tool.parameters),ctx.node('h3','Reusable argument definitions'),appSchemaEditor(ctx,tool.schemaDefinitions,'Definitions'),appToggle(ctx,'Represent nil explicitly',tool,'representNilExplicitlyInGeneratedContent'),ctx.button('Remove tool',() => {features.tools.splice(features.tools.indexOf(tool),1);ctx.changed();ctx.renderMain();},'quiet danger'));
    list.append(appDisclosure(ctx,tool.name || 'New tool',`${tool.parameters.length} arguments · ${tool.mode === 'localHTTP' ? 'Local HTTP endpoint' : 'Fixture response'}`,body,`tool-${tool.id}`));
  }
  list.append(ctx.button('+ Add tool',() => {const id=crypto.randomUUID();features.tools.push({id,name:'',description:'',mode:'fixture',fixtureResponse:'',endpoint:'',parameters:[],schemaDefinitions:[],representNilExplicitlyInGeneratedContent:false});(ctx.state.disclosures ||= {})[`tool-${id}`]=true;ctx.changed();ctx.renderMain();},'secondary',features.tools.length >= 4)); section.querySelector('.section-body').append(list);
  const vision = settings.visionTools ||= {ocrEnabled:false,barcodeEnabled:false};
  const builtins = appSection(ctx,'Built-in tools','Use Apple’s OCR and barcode tools with image references.',[appToggle(ctx,'Recognize text in images',vision,'ocrEnabled'),appToggle(ctx,'Read barcodes',vision,'barcodeEnabled')],'tools');
  const spotlight = features.spotlightSearch ||= {enabled:false};
  const search = appSection(ctx,'Spotlight search','Search local indexed files and inspect the recorded tool evidence.',[appToggle(ctx,'Enable Spotlight search',spotlight,'enabled',ctx.renderMain),...(spotlight.enabled ? appSpotlightControls(ctx,spotlight) : [])],'search');
  return [section,builtins,search];
}
function appOutputSection(ctx) {
  const features = appFeatureDefaults(ctx.state.draft), model = appModelDefaults(ctx.state.draft), customization = model.customization ||= {saveFullTranscript:true}; features.outputFields ||= [];features.outputSchemaDefinitions ||= [];
  return [appSection(ctx,'Response shape','Define a guided response with typed fields.',[appSelect(ctx,'Schema in prompt',customization,'schemaPrompt',[['included','Include schema'],['automatic','Framework default'],['omitted','Omit schema']]),appToggle(ctx,'Represent nil explicitly in generated content',features,'outputRepresentNilExplicitlyInGeneratedContent'),appSchemaEditor(ctx,features.outputFields)],'schema'),appSection(ctx,'Reusable definitions','Reference named types from your output fields.',[appSchemaEditor(ctx,features.outputSchemaDefinitions,'Definitions')],'schema')];
}
function appProfileSection(ctx) {
  const features = appFeatureDefaults(ctx.state.draft), profile = features.profile ||= {enabled:false};
  const controls = [appToggle(ctx,'Enable session profile',profile,'enabled',ctx.renderMain)];
  if (profile.enabled) controls.push(ctx.field('Profile name',profile.name || '',value => profile.name=value),ctx.field('Instructions after a tool call',profile.afterToolInstructions || '',value => profile.afterToolInstructions=value,true,'prompt-field'),appToggle(ctx,'Require a tool before the final response',profile,'requireToolFirst'),appSamplingControls(ctx,profile,'afterTool'),appNumber(ctx,'Maximum response tokens after a tool call',profile,'afterToolMaximumResponseTokens',128,4096,1,true),appSelect(ctx,'Reasoning after a tool call',profile,'afterToolReasoningLevel',[['automatic','Automatic'],['light','Light'],['moderate','Moderate'],['deep','Deep'],['custom','Custom']],ctx.renderMain),appSelect(ctx,'Transcript on tool error',profile,'afterToolTranscriptErrorPolicy',[['automatic','Framework default'],['preserve','Preserve failed request'],['revert','Revert failed request']]));
  if(profile.enabled && profile.afterToolReasoningLevel==='custom')controls.push(ctx.field('Custom reasoning after a tool call',profile.afterToolCustomReasoning || '',value=>profile.afterToolCustomReasoning=value));
  return appSection(ctx,'Session profile','Change instructions and generation settings between tool calls.',controls,'profile');
}
function appModelSection(ctx) {
  const draft=ctx.state.draft,model=appModelDefaults(draft),customization=model.customization ||= {saveFullTranscript:true};
  const controls=[appSelect(ctx,'Provider',model,'provider',[['onDevice','On device']]),appSelect(ctx,'Use case',customization,'useCase',[['general','General'],['contentTagging','Content tagging']]),appSelect(ctx,'Guardrails',customization,'guardrails',[['standard','Default'],['permissiveContentTransformations','Permissive text transformations']]),appSelect(ctx,'Reasoning',model,'reasoningLevel',[['automatic','Automatic'],['light','Light'],['moderate','Moderate'],['deep','Deep'],['custom','Custom']],ctx.renderMain),appSamplingControls(ctx,model),appNumber(ctx,'Maximum response tokens',model,'maximumResponseTokens',128,4096),appNumber(ctx,'Maximum input tokens',model,'maximumInputTokens',512,32768,1,true),appNumber(ctx,'Repetitions',draft,'repetitions',1,5),appSelect(ctx,'Reference files',model,'referenceMode',[['inline','Include in prompt'],['lookupTool','Search with a tool']]),appSelect(ctx,'Context policy',model,'contextPolicy',[['fitReferences','Fit reference content'],['requireFullInput','Require full input']])];
  if(model.reasoningLevel==='custom')controls.push(ctx.field('Custom reasoning preset',customization.customReasoning || '',value=>customization.customReasoning=value));
  return appSection(ctx,'Model & generation','Configure Apple’s on-device model and the workload.',controls,'cpu');
}
function appPerformanceSection(ctx) {
  const features=appFeatureDefaults(ctx.state.draft),model=appModelDefaults(ctx.state.draft),customization=model.customization ||= {saveFullTranscript:true};
  return appSection(ctx,'Performance','Measure streaming, prewarming and session evidence.',[appToggle(ctx,'Stream responses',features,'streamResponse'),appToggle(ctx,'Prewarm session',features,'prewarm'),ctx.field('Prewarm prefix',customization.prewarmPrefix || '',value => customization.prewarmPrefix=value),appNumber(ctx,'Prewarm lead time (seconds)',customization,'prewarmLeadSeconds',0,10,.1),appToggle(ctx,'Save full session transcript',customization,'saveFullTranscript'),appSelect(ctx,'Transcript after an error',customization,'transcriptErrorPolicy',[['automatic','Framework default'],['preserve','Preserve failed request'],['revert','Revert failed request']])],'clock');
}
export function renderNativeSetup(ctx) {
  if (!isAppSuiteFormat(ctx.state.draft)) {
    const draft = ctx.state.draft;
    return appSection(ctx, 'Suite setup', 'Each case keeps its own exact, contains, or trace-only scoring.', [
      ctx.field('Model instructions', draft.instructions || '', value => draft.instructions = value, true, 'instructions-editor'),
      appNumber(ctx, 'Temperature', draft, 'temperature', 0, 2, .05),
      appNumber(ctx, 'Maximum response tokens', draft, 'maxTokens', 1, 4096),
      appNumber(ctx, 'Repetitions', draft, 'repetitions', 1, 10),
    ], 'instructions');
  }
  const layout=ctx.node('div',null,'setup-layout'),nav=ctx.node('nav',null,'setup-navigation');nav.setAttribute('aria-label','Suite setup');nav.append(ctx.node('p','Suite setup','sidebar-label'));
  ctx.state.setupPage ||= 'instructions';
  for (const [key,title,subtitle,symbol] of APP_SETUP_PAGES) {
    const row=ctx.button('',() => {ctx.state.setupPage=key;ctx.renderMain();},'setup-nav-row');row.setAttribute('aria-pressed',String(ctx.state.setupPage===key));row.title=subtitle;row.append(ctx.icon(symbol),ctx.node('span',title));nav.append(row);
  }
  const content=ctx.node('div',null,'setup-content'),[key,title,subtitle,symbol]=APP_SETUP_PAGES.find(([id])=>id===ctx.state.setupPage),heading=ctx.node('div',null,'setup-page-heading'),mark=ctx.node('div',null,'page-symbol');mark.append(ctx.icon(symbol));const copy=ctx.node('div');copy.append(ctx.node('h2',title),ctx.node('p',subtitle));heading.append(mark,copy);content.append(heading);
  if(key==='instructions')content.append(appSection(ctx,'Model instructions','Tell the model how to respond across all cases.',[ctx.field('Model instructions',ctx.state.draft.instructions,value=>ctx.state.draft.instructions=value,true,'instructions-editor')] ,'instructions'),appReferenceSection(ctx),ctx.button('Compare instructions',ctx.createExperiment,'secondary'));
  if(key==='scoring') {
    content.append(appScoringSection(ctx));
    if(ctx.state.draft.scoringMode==='modelJudge') {
      const judge=ctx.state.draft.judgeConfiguration ||= {mode:'sameModel',includeReferenceAttachments:true};content.append(appSection(ctx,'Judge','The same on-device model checks every requirement.',[appToggle(ctx,'Include reference files for judging',judge,'includeReferenceAttachments')],'file'));
    }
    content.append(appReleaseSection(ctx));
  }
  if(key==='model')content.append(appModelSection(ctx));
  if(key==='tools')content.append(...appToolsSection(ctx));
  if(key==='output')content.append(...appOutputSection(ctx));
  if(key==='profile')content.append(appProfileSection(ctx));
  if(key==='performance')content.append(appPerformanceSection(ctx));
  layout.append(nav,content);return layout;
}

function appSpotlightControls(ctx, config) {
  const controls=[], attributes=(object,label)=>{
    object.fetchedAttributes ||= {presets:[],customAttributeNames:[]};const container=ctx.node('div',null,'disclosure-body');
    const presets=['identifier','displayName','title','subject','contentDescription','textContent','keywords','contentType','path','contentURL','authorNames','recipientNames','creator','contentCreationDate','contentModificationDate','addedDate','lastUsedDate','fileSize','pageCount','duration'];
    for(const key of presets){const checkbox=ctx.node('label',null,'toggle-control'),input=ctx.node('input');input.type='checkbox';input.checked=object.fetchedAttributes.presets.includes(key);input.onchange=()=>{object.fetchedAttributes.presets=input.checked?[...object.fetchedAttributes.presets,key]:object.fetchedAttributes.presets.filter(value=>value!==key);ctx.changed();};checkbox.append(input,ctx.node('span',key));container.append(checkbox);}container.append(ctx.field('Custom attributes (one per line)',object.fetchedAttributes.customAttributeNames.join('\n'),value=>object.fetchedAttributes.customAttributeNames=value.split('\n').filter(Boolean),true,'compact-editor'));return appDisclosure(ctx,label,'Attributes returned with search results.',container,label);
  };
  config.fileSource ||= {enabled:false,folderPath:'',maximumResults:10};config.coreSpotlightSource ||= {enabled:false,allowMail:false,maximumResults:10};config.guidance ||= {mode:'complete',focusedDomain:'documents',outputFormat:'structured'};config.contactIdentity ||= {enabled:false};config.pipeline ||= {deduplicateItems:true};
  const files=config.fileSource,index=config.coreSpotlightSource,guidance=config.guidance,identity=config.contactIdentity;
  controls.push(appToggle(ctx,'Search files',files,'enabled',ctx.renderMain));if(files.enabled)controls.push(ctx.field('Folder path',files.folderPath,value=>files.folderPath=value),appNumber(ctx,'Maximum file results',files,'maximumResults',1,50),attributes(files,'File attributes'));
  controls.push(appToggle(ctx,'Search Core Spotlight',index,'enabled',ctx.renderMain));if(index.enabled)controls.push(appToggle(ctx,'Include Mail',index,'allowMail'),appNumber(ctx,'Maximum indexed results',index,'maximumResults',1,50),attributes(index,'Indexed attributes'));
  controls.push(appSelect(ctx,'Search guidance',guidance,'mode',[['complete','Complete'],['focused','Focused'],['dynamic','Dynamic']],ctx.renderMain));if(guidance.mode==='focused')controls.push(appSelect(ctx,'Focused domain',guidance,'focusedDomain',[['items','Items'],['documents','Documents'],['communications','Communications'],['calendar','Calendar'],['audio','Audio'],['visualMedia','Visual media']]));
  if(guidance.mode==='dynamic'){const profile=guidance.dynamicProfile ||= {};for(const key of ['textMatch','similarityMatch','numericMatch','dates','people','contentType'])controls.push(appSelect(ctx,key,profile,key,[['unused','Unused'],['allowed','Allowed'],['disallowed','Disallowed']]));const adapter={fetchedAttributes:profile.attributes || {presets:[],customAttributeNames:[]}};profile.attributes=adapter.fetchedAttributes;controls.push(attributes(adapter,'Guidance attributes'));}
  controls.push(appSelect(ctx,'Search output',guidance,'outputFormat',[['structured','Structured'],['compact','Compact']]),appToggle(ctx,'Deduplicate items',config.pipeline,'deduplicateItems'),appNumber(ctx,'Maximum search response size',config,'maximumResponseSize',256,4096),appToggle(ctx,'Contact identity',identity,'enabled',ctx.renderMain));
  if(identity.enabled){controls.push(ctx.field('Display name',identity.displayName || '',value=>identity.displayName=value));for(const [key,label] of [['alternateNames','Alternate names'],['emailAddresses','Email addresses'],['phoneNumbers','Phone numbers']])controls.push(ctx.field(label+' (one per line)',(identity[key] || []).join('\n'),value=>identity[key]=value.split('\n').filter(Boolean),true,'compact-editor'));}return controls;
}
