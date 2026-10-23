// Native evaluation workflows share the same frozen suite and evidence contracts.
export function promptRewriteRequest(source,action,editingRequest='') {
  const instructions={shorten:'Rewrite the evaluation prompt below to say the same thing in fewer words. Preserve every requirement, constraint, and expected output detail. Return only the revised prompt.',tone:'Rewrite the evaluation prompt below with a clear, direct tone while preserving every requirement, constraint, and expected output detail. Return only the revised prompt.',grammar:'Fix the spelling, grammar, and punctuation of the evaluation prompt below without changing its requirements or meaning. Return only the revised prompt.',prompt:'Revise the evaluation prompt below according to the editing request. Preserve every requirement that the request does not ask to change. Return only the revised prompt.',rewrite:'Rewrite the evaluation prompt below for clarity and precision. Preserve every requirement, constraint, and expected output detail. Return only the revised prompt.'};
  return `${instructions[action] || instructions.rewrite}\n\n${editingRequest ? editingRequest+'\n\n' : ''}Original evaluation prompt:\n${source}`;
}
export function canKeepRevision(current,original) { return current===original; }
export function watchPromptPreview({previewId,readStatus,cancel,onResponse,schedule=setInterval,unschedule=clearInterval}) {
  let stopped=false,polling=false;
  const poll=async()=>{if(stopped || polling)return;polling=true;try{const {preview}=await readStatus();const text=typeof preview?.liveResponse==='string'?preview.liveResponse:preview?.liveResponse?.text;if(!stopped && preview?.id===previewId && typeof text==='string')onResponse(text);}catch{}finally{polling=false;}};
  const timer=schedule(poll,300);
  return {poll,finish(){stopped=true;unschedule(timer);},close(){if(stopped)return Promise.resolve();stopped=true;unschedule(timer);return cancel(previewId);}};
}
export async function nativeRewritePrompt(ctx,test,action) {
  const original=test.prompt,owner=ctx.state.draft,suiteId=owner.id;
  ctx.dialog('Writing tools',el=>{
    let watcher=null,closed=false;
    el.addEventListener('close',()=>{closed=true;watcher?.close().catch(()=>{});});
    const request=ctx.node('textarea');request.setAttribute('aria-label','Editing request');request.placeholder='Describe how to revise this prompt.';request.hidden=action!=='prompt';
    const preview=ctx.node('pre','Choose Preview to generate a revision.','content-well'),actions=ctx.node('div',null,'actions');
    const keep=ctx.button('Keep',()=>{if(ctx.state.draft!==owner || !owner.cases.includes(test) || ctx.state.draft?.id!==suiteId || !canKeepRevision(test.prompt,original))throw Error('The prompt changed while this revision was being generated. Generate a new revision before keeping it.');test.prompt=preview.textContent;ctx.changed();ctx.renderMain();el.close();},'primary',true);
    const generate=ctx.button('Preview',async()=>{
      generate.disabled=true;keep.disabled=true;preview.textContent='Revising with Apple Foundation Models…';
      const previewId=crypto.randomUUID();
      watcher=watchPromptPreview({previewId,readStatus:()=>ctx.call('eval_preview_status'),cancel:id=>ctx.call('eval_cancel_preview',{previewId:id}),onResponse:text=>{if(text)preview.textContent=text;}});
      try {
        const suite=ctx.newSuite(ctx.state.projectId);suite.instructions='You revise test-case prompts for an evaluation workbench. Return only the revised prompt text, with no preamble or explanation.';suite.scoringMode='review';suite.features.streamResponse=true;suite.modelConfiguration.maximumResponseTokens=1024;suite.modelConfiguration.customization.toolCalling='disallowed';
        const result=await ctx.call('eval_preview_response',{suite,prompt:promptRewriteRequest(original,action,request.value),previewId});
        if(closed)return;
        if(!result.response?.trim())throw Error('The model returned an empty revision.');
        preview.textContent=result.response.trim();keep.disabled=false;generate.textContent='Retry';
      } catch(error) {if(!closed)throw error;} finally {watcher.finish();if(!closed)generate.disabled=false;}
    },'secondary',ctx.active());
    actions.append(generate,keep,ctx.button('Discard',()=>el.close(),'secondary'));el.append(request,preview,actions);
  });
}
export function createInstructionExperiment(ctx) {
  const owner = ctx.state.draft;
  ctx.dialog('Compare instructions', el => {
    const name = ctx.node('input'); name.value = 'Instruction comparison'; name.setAttribute('aria-label', 'Experiment name');
    const candidate = ctx.node('textarea', owner.instructions, 'json-editor'); candidate.setAttribute('aria-label', 'Candidate instructions');
    el.append(ctx.node('p', 'Current and candidate instructions run against the same frozen cases, model settings and scoring contract. Samples are interleaved.', 'hint'), name, candidate,
      ctx.button('Create experiment', async () => {
        const request = ctx.scope.capture('experiment-selection');
        await ctx.flush();
        if (!ctx.scope.current(request) || ctx.state.draft !== owner) return;
        const result = await ctx.call('eval_create_experiment', { suiteId: owner.id, expectedRevision: owner.revision, name: name.value, candidateInstructions: candidate.value });
        if (!ctx.scope.current(request) || ctx.state.draft !== owner) return;
        ctx.trackExperiment(result.experiment);
        ctx.state.experiment = result.experiment; ctx.state.experimentSummary = null; ctx.state.suiteTab = 'compare';
        el.close(); ctx.render();
      }, 'primary'));
  });
}
export function renderExperiment(ctx,parent) {
  const record=ctx.state.experiment;if(!record)return;
  const owner=ctx.state.draft;
  const current=request=>ctx.scope.current(request) && ctx.state.draft===owner && ctx.state.experiment?.id===record.id;const panel=ctx.node('section',null,'surface experiment-panel');panel.append(ctx.panelHeader(record.name || record.experiment?.name || 'Instruction experiment'));
  const body=ctx.node('div',null,'panel-content');body.append(ctx.node('p',`Status: ${record.status}`,'hint'));const decisionLabels={keepCurrent:'Keep current',adoptCandidate:'Adopt candidate',collectMoreEvidence:'Collect more evidence',inconclusive:'Inconclusive'};if(record.experiment?.decision)body.append(ctx.node('p','Decision: '+(decisionLabels[record.experiment.decision] || record.experiment.decision),'hint'));
  if(!['completed','running'].includes(record.status))body.append(ctx.button('Run experiment',async()=>{const request=ctx.scope.capture('experiment-selection');await ctx.flush();if(!current(request))return;const result=await ctx.call('eval_run_experiment',{experimentId:record.id});ctx.trackExperiment(result.experiment);if(!current(request))return;ctx.state.experiment=result.experiment;ctx.state.experimentSummary=result.summary;await ctx.refresh();if(current(request))ctx.renderMain();},'primary',ctx.active()));
  if(record.status==='running')body.append(ctx.button('Cancel experiment',async()=>{const request=ctx.scope.capture('experiment-selection');const result=await ctx.call('eval_cancel_experiment',{experimentId:record.id});ctx.trackExperiment(result.experiment);if(!current(request))return;ctx.state.experiment=result.experiment;await ctx.refresh();if(current(request))ctx.renderMain();},'danger'));
  body.append(ctx.button('Refresh experiment',async()=>{const request=ctx.scope.capture('experiment-selection');const result=await ctx.call('eval_get_experiment',{experimentId:record.id});ctx.trackExperiment(result.experiment);if(!current(request))return;ctx.state.experiment=result.experiment;ctx.state.experimentSummary=result.summary;await ctx.refresh();if(current(request))ctx.renderMain();},'secondary'));
  if(ctx.state.experimentSummary){const summary=ctx.state.experimentSummary,metrics=ctx.node('div',null,'summary-cells');for(const [label,value] of [['Improved cases',summary.improvedCaseIDs.length],['Regressed cases',summary.regressedCaseIDs.length],['Case coverage',summary.distinctCaseCoverage],['Repetitions',summary.repetitionsPerCase],['Current median latency',ctx.duration(summary.currentMedianLatencyMilliseconds)],['Candidate median latency',ctx.duration(summary.candidateMedianLatencyMilliseconds)]])metrics.append(ctx.metric(label,value));body.append(metrics,ctx.node('p',summary.explanation,'hint'));const table=ctx.node('table',null,'data-table');for(const [label,ids] of [['Improved',summary.improvedCaseIDs],['Regressed',summary.regressedCaseIDs],['Unchanged',summary.unchangedCaseIDs]]){const row=ctx.node('tr');row.append(ctx.node('th',label),ctx.node('td',ids.map(id=>ctx.state.draft.cases.find(item=>item.id.toLowerCase()===id.toLowerCase())?.name || id).join(', ') || 'None'));table.append(row);}body.append(table);if(summary.confidenceInterval)body.append(ctx.node('p','Confidence interval: '+JSON.stringify(summary.confidenceInterval),'hint'));}
  if(record.status==='completed'){const decisions=ctx.node('div',null,'actions');for(const [decision,label] of [['keepCurrent','Keep current'],['adoptCandidate','Adopt candidate'],['collectMoreEvidence','More evidence'],['inconclusive','Inconclusive']])decisions.append(ctx.button(label,async()=>{const request=ctx.scope.capture('experiment-selection');if(!current(request))return;const result=await ctx.mutateSuite(()=>ctx.call('eval_decide_experiment',{experimentId:record.id,decision,expectedRevision:record.revision}),owner);if(!result || !current(request))return;ctx.trackExperiment(result.experiment);ctx.state.experiment=result.experiment;await ctx.refresh();if(current(request))ctx.render();},decision==='adoptCandidate'?'primary':'secondary'));body.append(decisions);}panel.append(body);parent.append(panel);
}
export function nativeCorrectJudgment(ctx,run,result) {
  const sample=result.appSample || result.trace?.appSample;
  if(!sample?.id)throw Error('This older result has no application sample identity.');
  const selectedID=result.assessmentId || run.appRun?.selectedAssessmentID;
  const assessment=selectedID
    ? run.appRun?.assessments?.find(item=>item.id?.toLowerCase()===selectedID.toLowerCase())
    : run.appRun?.assessments?.at(-1);
  const assessed=assessment?.samples?.find(item=>item.sampleID?.toLowerCase()===sample.id.toLowerCase());
  if(!assessment?.id || !assessed)throw Error('The selected assessment judgment is unavailable. Reload the run before correcting it.');
  if(typeof run.revision!=='string' || !run.revision)throw Error('The run revision is unavailable. Reload the run before correcting it.');
  const statuses=['passed','failed','unscored','error'];
  if(!statuses.includes(assessed.status))throw Error('The selected assessment outcome is unavailable. Reload the run before correcting it.');
  const target={runId:run.id,sampleId:sample.id,assessmentId:assessment.id,expectedRevision:run.revision};
  const owner=ctx.scope.capture();
  const current=()=>ctx.scope.current(owner) && ctx.state.run?.id===target.runId && ctx.state.run?.revision===target.expectedRevision;
  ctx.dialog('Human correction',el=>{
    const status=ctx.node('select');status.setAttribute('aria-label','Corrected outcome');
    for(const value of statuses)status.append(new Option(value,value));status.value=assessed.status;
    const score=ctx.node('input');score.type='number';score.min='1';score.max='4';score.value=assessed.score ?? '';score.setAttribute('aria-label','Corrected score');
    const reason=ctx.node('textarea');reason.setAttribute('aria-label','Reason for correction');
    const reviewer=ctx.node('input');reviewer.setAttribute('aria-label','Reviewer');reviewer.placeholder='Reviewer (optional)';
    el.append(ctx.node('p','The original model judgment remains in the run. This correction is recorded separately with its reason and time.','hint'),status,score,reason,reviewer,ctx.button('Record correction',async()=>{
      if(!current())throw Error('The selected run changed. Reload it and reopen Human correction.');
      const request=ctx.scope.capture('run-assessment');
      const response=await ctx.call('eval_correct_judgment',{...target,correctedStatus:status.value,...score.value?{correctedScore:Number(score.value)}:{},reason:reason.value,...reviewer.value?{reviewer:reviewer.value}:{}});
      el.close();
      if(!ctx.scope.current(request) || !current())return;
      ctx.state.run=response.run;
      await ctx.refresh();if(ctx.scope.current(request))ctx.renderMain();
    },'primary'));
  });
}
export async function nativeApproveBaseline(ctx,run) {
  ctx.dialog('Approve baseline',el=>{const note=ctx.node('textarea');note.setAttribute('aria-label','Baseline note');el.append(ctx.node('p','Approval is tied to this completed run, its selected assessment, saved suite revision and scoring contract.','hint'),note,ctx.button('Approve baseline',async()=>{const request=ctx.scope.capture();await ctx.flush();if(!ctx.scope.current(request))return;await ctx.call('eval_approve_baseline',{runId:run.id,...run.appRun?.selectedAssessmentID?{assessmentId:run.appRun.selectedAssessmentID}:{},note:note.value});el.close();if(!ctx.scope.current(request))return;ctx.notice('Baseline approved for this suite.');ctx.renderMain();},'primary'));});
}
export async function nativeReleaseReport(ctx,run) {const request=ctx.scope.capture();const result=await ctx.call('eval_release_report',{runId:run.id});if(!ctx.scope.current(request) || ctx.state.run?.id!==run.id)return;ctx.dialog('Release report',el=>el.append(ctx.node('pre',result.markdown || JSON.stringify(result.report,null,2),'content-well')));}
export async function nativeAnalyzeRun(ctx,run) {
 const request=ctx.scope.capture();
 const result=await ctx.call('eval_analyze_run',{runId:run.id}),analysis=result.analysis;
 if(!ctx.scope.current(request) || ctx.state.run?.id!==run.id)return;
 ctx.dialog('Run analysis',el=>{
  if(!analysis){el.append(ctx.node('p','This older run has no application analysis.','hint'));return;}
  const metrics=ctx.node('div',null,'summary-cells');for(const [label,value] of [['Completed',`${analysis.completedSampleCount} / ${analysis.plannedSampleCount}`],['Missing',analysis.missingSampleCount],['Scored pass rate',ctx.rate(analysis.scoredPassRate)],['Errors',analysis.errorSampleCount],['Subject p50',ctx.duration(analysis.subjectLatency?.p50Milliseconds)],['Subject p95',ctx.duration(analysis.subjectLatency?.p95Milliseconds)]])metrics.append(ctx.metric(label,value));el.append(metrics);
  const usage=ctx.node('table',null,'data-table');for(const [label,item] of [['Subject usage',analysis.subjectUsage],['Judge usage',analysis.judgeUsage]]){const row=ctx.node('tr');row.append(ctx.node('th',label),ctx.node('td',`${item?.inputTokens || 0} input · ${item?.outputTokens || 0} output · ${item?.usageUnavailableSampleCount || 0} requests without usage`));usage.append(row);}el.append(usage);
  const cases=ctx.node('table',null,'data-table'),head=ctx.node('tr');for(const title of ['Case','Coverage','Passed','Failed','Errors','Repeatability'])head.append(ctx.node('th',title));cases.append(head);
  for(const item of analysis.cases || []){const row=ctx.node('tr');for(const value of [item.caseName,`${item.completedSampleCount} / ${item.plannedSampleCount}`,item.passedSampleCount,item.failedSampleCount,item.errorSampleCount,item.repetitionVariation])row.append(ctx.node('td',value));cases.append(row);}el.append(cases);
  if(result.comparison)el.append(ctx.node('h3','Comparison evidence'),ctx.node('pre',JSON.stringify(result.comparison,null,2),'content-well'));
  if(result.corrections?.length)el.append(ctx.node('h3','Human corrections'),ctx.node('pre',JSON.stringify(result.corrections,null,2),'content-well'));
 });
}
