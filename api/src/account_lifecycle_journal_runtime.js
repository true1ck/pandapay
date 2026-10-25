'use strict';
const {createLifecycleJournal}=require('./account_lifecycle_journal');
const {CHECKPOINT_SQL}=require('./account_lifecycle_worker');
function createJournalRuntime({env=process.env,pool}={}){
 if(!['true','1'].includes(env.ACCOUNT_LIFECYCLE_ENABLED))return null;
 const journal=createLifecycleJournal({roots:[env.ACCOUNT_LIFECYCLE_JOURNAL_A,env.ACCOUNT_LIFECYCLE_JOURNAL_B],checkpointRoot:env.ACCOUNT_LIFECYCLE_CHECKPOINT_ROOT,journalId:env.ACCOUNT_LIFECYCLE_JOURNAL_ID,signingKey:env.ACCOUNT_LIFECYCLE_JOURNAL_AUTH_KEY,recipientsFile:env.ACCOUNT_LIFECYCLE_JOURNAL_RECIPIENTS_FILE,ageBinary:env.ACCOUNT_LIFECYCLE_JOURNAL_AGE_BINARY||'age'});
 async function readiness(){
  const actual=(await pool.query(CHECKPOINT_SQL,[false])).rows[0],expected=await journal.head();
  if(!actual||actual.journal_id!==expected.journal_id||Number(actual.sequence)!==expected.sequence||actual.head!==expected.head)throw Error('Lifecycle journal replay required before traffic');
 }
 return {journal,readiness};
}
module.exports={createJournalRuntime};
