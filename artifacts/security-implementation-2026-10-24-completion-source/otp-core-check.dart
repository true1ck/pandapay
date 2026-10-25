import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../app/lib/data/auth_api.dart';
void check(bool value,String message){if(!value)throw StateError(message);}
const id='bc3f590c-b3c9-412c-98eb-1be64946cb70';
Map<String,Object?> challenge()=>{'ok':true,'version':2,'challenge_id':id,'code_length':6,'expires_in':120};
Future<void> main()async{
 final calls=<http.Request>[];
 var now=DateTime.utc(2026,10,24);
 final api=AuthApi(authBaseUrl:'https://auth.test',versionedOtpEnabled:true,now:()=>now,client:MockClient((r)async{
  calls.add(r);return http.Response(jsonEncode(r.url.path.contains('/request-')?challenge():{'access_token':'synthetic-proof','refresh_token':'synthetic-refresh'}),200);
 }));
 final c=await api.requestEmailOtp('Person@example.test',deviceId:'device-1',isSignUp:true,phoneNumber:'+919999999999');
 check(calls[0].url.path=='/auth/v2/request-email-otp','v2 route');
 final request=jsonDecode(calls[0].body) as Map;check(request.length==2&&request['device_id']=='device-1'&&!request.containsKey('phone_number'),'no pre-proof identity selector');
 final result=await api.verifyEmailOtp('person@example.test','819273','device-1',challenge:c,phoneNumber:'+919999999999');
 check(result.accessToken=='synthetic-proof'&&jsonDecode(calls[1].body)['challenge_id']==id,'original binding');
 print('PASS: real client uses v2 email/device challenge without phone/signup selectors');
 for(final attempt in [()=>api.verifyEmailOtp('person@example.test','819273','device-2',challenge:c),()=>api.verifyEmailOtp('different@example.test','819273','device-1',challenge:c),()=>api.verifyEmailOtp('person@example.test','1234','device-1',challenge:c),()=>api.verifyEmailOtp('person@example.test','819273','device-1',challenge:c,recoveryOnly:true)]){
  var refused=false;try{await attempt();}on StateError{refused=true;}check(refused,'binding must refuse');
 }
 check(calls.length==2,'invalid verification must not send');
 print('PASS: real client rejects wrong device/contact/code/purpose before a request');
 now=now.add(const Duration(seconds:120));var expired=false;try{await api.verifyEmailOtp('person@example.test','819273','device-1',challenge:c);}on StateError{expired=true;}check(expired&&calls.length==2,'expiry');
 print('PASS: real client refuses an expired challenge locally');
 final failures=<String>[];
 final unavailable=AuthApi(authBaseUrl:'https://auth.test',versionedOtpEnabled:true,client:MockClient((r)async{failures.add(r.url.path);return http.Response('{}',404);}));
 var rejected=false;try{await unavailable.requestEmailOtp('person@example.test',deviceId:'device-1');}catch(_){rejected=true;}
 check(rejected&&failures.length==1&&failures[0]=='/auth/v2/request-email-otp','no downgrade');
 print('PASS: v2 missing upstream never downgrades to a legacy request');
 final legacyCalls=<http.Request>[];
 final legacy=AuthApi(authBaseUrl:'https://auth.test',client:MockClient((r)async{legacyCalls.add(r);return http.Response('{}',200);}));
 final old=await legacy.requestEmailOtp('person@example.test',isSignUp:true,phoneNumber:'+919999999999');
 final oldBody=jsonDecode(legacyCalls[0].body) as Map;
 check(old==null&&legacy.otpCodeLength==4&&legacyCalls[0].url.path=='/auth/request-email-otp'&&oldBody['is_signup']==true&&oldBody['phone_number']=='+919999999999','legacy compatibility');
 print('PASS: default legacy request shape and four-digit client remain compatible');
 for(final bad in [{...challenge(),'version':1},{...challenge(),'expires_in':121},{...challenge(),'challenge_id':'bad'}]){
  final invalid=AuthApi(authBaseUrl:'https://auth.test',versionedOtpEnabled:true,client:MockClient((_)async=>http.Response(jsonEncode(bad),200)));
  var failed=false;try{await invalid.requestEmailOtp('person@example.test',deviceId:'device-1');}catch(_){failed=true;}check(failed,'malformed challenge');
 }
 print('PASS: real client rejects malformed protocol, identifier and TTL metadata');
}
