import 'dart:async';
import '../../app/lib/data/portable_backup/account_recovery_operation_gate.dart';
void check(bool value,String message){if(!value)throw StateError(message);}
Future<void> main()async{
 final gate=AccountRecoveryOperationGate();
 await gate.run(()async{});check(gate.activeOperations==0,'ordinary release');
 print('PASS: core gate releases ordinary admission');
 final finish=Completer<void>();late Future<void> child;
 await gate.run(()async{child=gate.run(()=>finish.future);});
 check(gate.activeOperations==1,'nested child must outlive parent');
 var acquired=false;final exclusive=gate.exclusive(()async{acquired=true;check(gate.activeOperations==0,'all work drained');});
 await Future<void>.delayed(Duration.zero);check(!acquired,'must wait for child');
 var refused=false;try{gate.admit();}on AccountRecoveryBusy{refused=true;}
 check(refused,'new work must fail while closed');finish.complete();await child;await exclusive;
 check(acquired&&!gate.isRecovering,'exclusive finish');
 print('PASS: core gate drains unawaited nested child and rejects new work');
 final pending=Completer<void>();final job=gate.run(()=>pending.future);
 var timed=false;try{await gate.exclusive(()async{throw StateError('must not acquire');},drainTimeout:Duration.zero);}on TimeoutException{timed=true;}
 check(timed&&!gate.isRecovering&&gate.activeOperations==1,'timeout must preserve old work');pending.complete();await job;
 print('PASS: core gate timeout preserves admitted work and reopens admission');
 late Zone stale;
 await gate.run(()async{stale=Zone.current;});
 await gate.exclusive(()async{
  var blocked=false;try{await stale.run(()=>gate.run(()async{}));}on AccountRecoveryBusy{blocked=true;}
  check(blocked,'stale zone must not bypass closure');
 });
 print('PASS: completed parent zone cannot bypass a later recovery fence');
 final parentFinished=Completer<void>();
 final parent=gate.run(()async{await parentFinished.future;await gate.run(()async{});});
 final last=gate.exclusive(()async{});parentFinished.complete();await parent;await last;
 check(gate.activeOperations==0,'live nested work leaves no leak');
 print('PASS: previously admitted work completes nested operations during drain');
}
