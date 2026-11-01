# Palmi 개인정보 및 제3자 AI 서비스 고지

버전: v26.11  버전 일자: 2026.11.01

모델을 설정하기 전에 이 문서를 끝까지 읽어 주십시오. “읽었으며 동의합니다”를 선택하는 것은 이 문서에 설명된 데이터 흐름, 제3자 서비스와의 경계, 민감한 정보에 관한 주의 사항, 사용자 선택에 따른 책임을 이해하고 확인했다는 의미입니다. 표시되지 않은 제3자 약관에 동의했다는 의미는 아닙니다. 제3자 서비스의 공식 약관은 해당 서비스가 게시한 최신 페이지를 따릅니다.

## 1. 문서의 성격과 적용 범위

이 문서는 Palmi(PalmiAgent)가 처음 모델을 설정하기 전에 사용자에게 보여 주는 “개인정보 및 제3자 AI 서비스 고지”입니다. 기기 내 앱, 사용자가 선택한 모델 서비스, 시스템 권한, 제3자 도구 사이에서 발생할 수 있는 데이터 흐름을 설명하고, 모델 설정을 계속하기 전에 사용자의 명시적인 확인을 요청합니다.

이 문서는 특정 모델 제공자의 개인정보 처리방침이 아니며, 제3자 모델 제공자, 클라우드 사업자, 모델 애그리게이터, 기업 게이트웨이, 시스템 서비스 또는 로컬 배포 환경의 서비스 약관, 개인정보 처리방침, 개발자 계약, 데이터 처리 계약, 허용 가능한 사용 정책, 모델 라이선스 또는 안전 규칙을 대신하지 않습니다.

Palmi는 로컬 처리를 우선하는 Agent 앱이자 모델 연결을 위한 인터페이스입니다. 어떤 모델을 선택하는지, 어떤 Base URL을 입력하는지, 어떤 API 키를 사용하는지, 어떤 내용을 전송하는지, 어떤 시스템 권한이나 도구를 사용하도록 설정하는지에 따라 데이터가 기기 밖으로 나가는지와 누가 처리하는지가 결정됩니다.

## 2. 현재 제품 설계에서의 로컬 데이터 처리

현재 제품 설계에서 Palmi는 채팅 내용, 작업 공간 파일, 첨부 파일 또는 API 키를 위한 자체 중앙 서버 데이터베이스를 운영하지 않습니다. 프로젝트, 대화, 작업 공간 파일, 첨부 파일, 실행 기록, 캐시, 환경설정은 주로 기기의 앱 컨테이너에 저장됩니다. 모델 자격 증명은 시스템 키체인 또는 이와 동등한 안전한 자격 증명 저장소에 보관되어야 합니다.

로컬 OCR, 파일 미리 보기, 작업 공간 읽기와 쓰기, 내장 Python, 로컬 캐시, 대화 관리, 데이터 정리는 일반적으로 기기에서 실행됩니다. 원격 모델, 원격 검색, 원격 파일 서비스, 클라우드 동기화, 공유 또는 내보내기, 기타 제3자 기능을 설정하지 않는 한, 이러한 내용은 일반적으로 Palmi 자체에 의해 Palmi가 운영하는 원격 서버로 전송되지 않습니다.

기기 수준의 시스템, iCloud 또는 시스템 백업, 충돌 진단, App Store, 기업 모바일 기기 관리, 네트워크 프록시, VPN, 보안 도구, 사용자가 직접 내보낸 파일은 Apple, 조직 관리자, 네트워크 서비스 또는 사용자가 선택한 제3자의 규칙에 따라 데이터를 처리할 수 있습니다. Palmi는 이러한 시스템 수준의 처리나 사용자가 선택한 처리를 통제하지 않습니다.

## 3. 데이터가 기기 밖으로 나갈 수 있는 경우

원격 모델 서비스, 모델 애그리게이터, 클라우드에서 호스팅되는 엔드포인트, 기업 게이트웨이 또는 사용자 지정 OpenAI 호환 엔드포인트를 설정하고 사용하는 경우, 모델에 보내는 프롬프트, 컨텍스트, 파일 요약, 이미지, 도구 결과, 모델 역할 설정, 시스템 지시의 일부, 대화 기록, 오류 정보, 필요한 요청 메타데이터가 해당 서비스로 전송될 수 있습니다.

웹 검색, 웹 페이지 읽기, 지도, 메일, 메시지, 전화, 캘린더, 미리 알림, 연락처, 위치, 카메라, 사진, 음성 인식, 알림, Spotlight, 시스템 라우팅 또는 기타 도구 기능을 사용하도록 설정하면, 관련 데이터가 해당 시스템 서비스, 검색 제공자, 웹사이트, 계정 서비스, 기업 환경 또는 네트워크 서비스에 의해 처리될 수 있습니다.

파일을 가져오거나, 열거나, 복사하거나, 공유하거나, 내보내거나, 전송하거나, 업로드하거나, Agent에게 파일에 대한 외부 작업을 지시하면, 해당 파일이나 그 내용이 사용자가 선택한 위치에 기록되거나, 사용자가 선택한 앱, 제공자 또는 연락처로 전송되거나, 관련 시스템의 캐시와 로그에 남을 수 있습니다.

네트워크 전송에는 일반적으로 네트워크 연결이 필요합니다. 통신사, DNS 제공자, 프록시, VPN, 게이트웨이, 방화벽, 기업 보안 제품 또는 제3자 SDK나 서비스는 각자의 규칙에 따라 네트워크 메타데이터를 처리할 수 있습니다.

## 4. 모델 서비스, OpenAI 호환 엔드포인트 및 책임의 범위

“OpenAI 호환”은 엔드포인트 형태, 인증 방식, 요청 형식, 메시지 구조, 스트리밍 또는 도구 호출 형식이 OpenAI 생태계와 유사하다는 뜻일 뿐입니다. 해당 서비스를 OpenAI가 운영한다는 뜻이 아니며, 보안, 보관, 학습 활용, 삭제, 국외 이전, 분쟁 해결 또는 준거법 규칙이 OpenAI와 같다는 뜻도 아닙니다.

제3자 모델 서비스, 클라우드 사업자, 모델 애그리게이터, 기업 게이트웨이, 자체 호스팅 서비스는 각각 독립적인 개인정보처리자, 수탁자, 공동 처리자, 인프라 제공자 또는 모델 호스트의 역할을 할 수 있습니다. 로그 기록, 입력과 출력의 보관, 안전성 검토, 모델 학습 활용, 상위 모델로의 전달, 삭제 요청 처리, 정부나 규제 기관의 요청에 대한 대응은 각 사업자의 최신 정책과 계정 계약을 따릅니다.

Palmi는 사용자가 입력한 엔드포인트의 소유자, API 키의 출처, 계정 권한, 서비스 지역, 요금 책임, 보관 기간, 학습 설정, 데이터 미보관 설정, 기업용 데이터 보호 조항 또는 실제 상위 모델 처리자를 사용자를 대신해 확인할 수 없습니다. 사용하기 전에 이러한 사항을 직접 확인하시기 바랍니다.

## 5. 민감한 내용, 기업 자료 및 타인에 관한 데이터

충분한 권한, 법적 근거, 보안 검토 없이 비밀번호, API 키, 개인 키, 신분 번호, 은행 카드, 건강 정보, 미성년자 정보, 정확한 위치, 연락처, 채팅 기록, 고객 데이터, 소스 코드상의 기밀, 영업 비밀, 미공개 연구, 비밀 유지 계약으로 보호되는 내용, 규제 대상 데이터 또는 타인의 권리를 침해할 수 있는 자료를 모델이나 도구에 제출해서는 안 됩니다.

회사, 학교, 연구실, 프로젝트 팀, 고객, 가족 또는 기타 제3자를 대신하여 Palmi를 사용하는 경우, 모델 서비스 설정, 관련 내용 전송, 시스템 권한 부여, 도구 호출, 파일 업로드 또는 내보내기에 대한 권한이 있는지 확인하고, 해당 조직의 데이터 분류, 기밀 유지, 컴플라이언스, 구매 및 보안 승인 요건을 따라야 합니다.

어떤 정보를 모델이나 제3자 서비스로 보내도 되는지 확실하지 않다면 기본적으로 보내지 마십시오. 가명 처리, 요약, 익명화, 로컬 처리, 내부 승인 또는 해당 컴플라이언스 요건을 충족하는 기업용 서비스 이용을 고려하시기 바랍니다.

## 6. 도구 호출, 시스템 권한 및 외부 작업

Palmi의 Agent 기능은 파일 읽기, 파일 생성, 작업 공간 변경, 웹 검색, 캘린더·미리 알림·연락처·위치·사진·카메라·음성에 대한 접근, 시스템 앱 열기, 메시지 초안 작성 또는 기타 시스템 작업을 제안하거나 실행할 수 있습니다. 도구에 따라 iOS 권한, 사용자 확인, 제3자 계정 승인 또는 조직 정책상의 허가가 필요할 수 있습니다.

외부 시스템, 다른 사람, 계정 자산, 일정, 파일 상태, 메시지 전송, 구매, 결제, 배포, 삭제 또는 공개에 영향을 줄 수 있는 작업은 실행 전에 사람이 검토해야 합니다. 모델의 출력은 불완전하거나, 부정확하거나, 오래되었거나, 사실이 아니거나, 편향되었거나, 사용자의 의도와 다를 수 있습니다.

자동 승인, 일괄 실행, 스크립트 실행, 웹 자동화, 시스템 라우팅 또는 기업 도구 연동을 사용하도록 설정하면 위험이 크게 높아집니다. 이러한 기능은 신뢰할 수 있는 작업과 되돌릴 수 있는 환경에서만 사용하십시오.

## 7. 로컬 데이터 관리, 동의 철회 및 삭제

로컬 데이터와 제3자 계정 데이터는 앱 내 데이터 관리, 시스템 설정, iOS 권한 설정, 키체인 또는 자격 증명 재설정, 제공자 콘솔, 제3자 계정 관리 페이지, 조직 관리자, 클라우드 사업자 문의 또는 앱 삭제를 통해 관리할 수 있습니다.

Palmi의 로컬 작업 공간, 캐시, 환경설정 또는 모델 자격 증명을 지우면 기기에 있는 데이터나 Palmi가 보관한 사본에만 영향을 줍니다. 이미 제3자 모델 서비스, 검색 제공자, 웹사이트, 클라우드 사업자, 애그리게이터, 기업 게이트웨이, 시스템 서비스 또는 기타 앱으로 전송된 데이터는 자동으로 삭제되지 않습니다. 제3자 측 데이터의 열람, 정정, 내보내기, 삭제, 학습 중단, 메모리 또는 로그 보관 설정은 해당 제공자의 정책과 계정 도구에 따라 처리해야 합니다.

앱을 삭제하더라도 시스템 백업, 기업 기기 관리, 로그, 내보낸 파일, 공유된 사본, 제3자의 보관 기간, 법적 보존 의무의 영향을 받을 수 있습니다.

## 8. AI 출력 및 전문적 위험에 관한 고지

모델의 출력은 법률, 의료, 금융, 투자, 세무, 공학적 안전, 정신 건강, 고용, 이민, 교육 또는 기타 전문적인 조언이 아닙니다. 위험이 높거나 전문적인 상황에서는 자격을 갖춘 전문가와 상담하고 결과를 독립적으로 검증하십시오.

모델은 잘못된 사실, 결함이 있는 코드, 잘못된 인용, 오해를 일으키는 보안 조언, 실행할 수 없는 계획, 오래된 정책, 존재하지 않는 링크 또는 부적절한 내용을 생성할 수 있습니다. 모델의 출력을 사용, 배포, 실행, 제출하거나 이에 의존할지는 신중하게 판단해야 합니다.

Palmi는 도구이자 작업 흐름을 위한 인터페이스입니다. 제3자 모델, 엔드포인트, 도구, 검색 소스, 시스템 서비스 또는 사용자 설정이 항상 사용 가능하고, 정확하고, 안전하고, 규정을 준수하거나, 특정 목적에 적합하다고 보장하지 않습니다.

## 9. 주요 모델 서비스의 정책 안내

아래에는 Palmi의 현재 빠른 항목, 유지되고 있거나 널리 쓰이는 OpenAI 호환 제공자, 애그리게이터, 사용자 지정 모델 서비스와 관련될 수 있는 정책 안내를 정리했습니다. 링크는 이 문서 버전을 작성할 때 수집한 공개 페이지 또는 공식 콘솔입니다. 제공자는 국가나 지역, 계정 유형, 기업 계약, API 상품, 모델, 호스팅 경로, 상위 제공자에 따라 다른 약관을 표시할 수 있습니다. 사용하기 전에 제공자의 최신 페이지를 확인하십시오.

### Zhipu AI / GLM / Z.ai / BigModel

Palmi에서 현재 선택할 수 있는 빠른 제공자 항목 중 하나입니다. 사용자 지정 OpenAI 호환 엔드포인트를 통해 사용될 수도 있습니다.

- [BigModel / Zhipu 오픈 플랫폼](https://open.bigmodel.cn/)
- [Z.ai 공식 사이트](https://z.ai/)

사용하기 전에 콘솔이나 로그인 화면에 표시되는 최신 서비스 약관, 개인정보 처리방침, 개발자 약관, 데이터 처리 조항을 확인하십시오.

### DeepSeek

Palmi에서 현재 선택할 수 있는 빠른 제공자 항목 중 하나입니다. 공식 API, 애그리게이터 또는 사용자 지정 엔드포인트를 통해 사용될 수도 있습니다.

- [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek Terms of Use](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### 사용자 지정 OpenAI 호환 엔드포인트

사용자가 입력한 Base URL, API 키, 모델 이름을 사용합니다. 실제 서비스는 공식 제공자, 애그리게이터, 클라우드 호스트, 기업 게이트웨이, 로컬 서버 또는 자체 호스팅 서비스일 수 있습니다.

“OpenAI 호환”은 API의 형태만을 나타내며, OpenAI가 해당 엔드포인트를 운영한다는 뜻이나 개인정보, 보관, 학습, 삭제, 이전 규칙이 같다는 뜻이 아닙니다.

데이터를 보내기 전에 엔드포인트 소유자, 조직 게이트웨이 또는 자체 호스팅 시스템의 최신 정책을 확인하십시오.

### OpenAI / ChatGPT

사용자 지정 엔드포인트, OpenRouter, Azure OpenAI 또는 기타 호스팅 경로를 통해 사용될 수 있습니다.

- [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

Azure 리소스, 기업 계정 또는 사용자 지정 엔드포인트를 통해 사용될 수 있습니다.

- [Microsoft Privacy Statement](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Azure OpenAI data, privacy, and security](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### Alibaba Cloud Model Studio / DashScope / Qwen

Alibaba Cloud Model Studio 또는 DashScope의 OpenAI 호환 엔드포인트, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [Alibaba Cloud 개인정보 처리방침](https://www.aliyun.com/legal/privacy)
- [DashScope / Model Studio 문서](https://help.aliyun.com/zh/dashscope/)

기업 계정을 사용하는 경우 Alibaba Cloud 서비스 약관, 데이터 처리 계약, 선택한 지역의 규칙도 확인하십시오.

### Moonshot AI / Kimi

Kimi / Moonshot 공식 API, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [Moonshot AI 오픈 플랫폼](https://platform.moonshot.cn/)
- [Kimi 공식 사이트](https://kimi.moonshot.cn/)

오픈 플랫폼이나 로그인 화면에 표시되는 최신 개인정보 처리방침, 서비스 약관, API 약관을 확인하십시오.

### MiniMax / Hailuo / Talkie

MiniMax 공식 API, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [MiniMax 공식 사이트](https://www.minimax.io/)
- [MiniMax 오픈 플랫폼](https://platform.minimaxi.com/)

오픈 플랫폼과 계정 관리 화면에 표시되는 개인정보 처리방침, 서비스 약관, API 약관을 확인하십시오.

### Volcengine Ark / Doubao

Volcengine Ark의 OpenAI 호환 엔드포인트, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [Volcengine 개인정보 처리방침](https://www.volcengine.com/docs/6256/64902)
- [Volcengine Ark 문서](https://www.volcengine.com/docs/82379)

### Tencent Hunyuan

Tencent Cloud Hunyuan API, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [Tencent Cloud 개인정보 보호 성명](https://cloud.tencent.com/document/product/301/11470)
- [Tencent Cloud 서비스 약관](https://cloud.tencent.com/document/product/301/1967)

### Baidu Qianfan / ERNIE

Baidu AI Cloud Qianfan 엔드포인트, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [Baidu 개인정보 보호 플랫폼](https://privacy.baidu.com/policy)
- [Baidu AI Cloud Qianfan 문서](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### StepFun

StepFun 공식 API, 사용자 지정 엔드포인트 또는 애그리게이터를 통해 사용될 수 있습니다.

- [StepFun 오픈 플랫폼](https://platform.stepfun.com/)

StepFun 콘솔에 표시되는 서비스 약관, 개인정보 처리방침, 개발자 약관을 확인하십시오.

### ModelScope

모델 호스팅 또는 추론 서비스의 창구로 사용될 수 있습니다.

- [ModelScope 공식 사이트](https://modelscope.cn/)

ModelScope 서비스 약관, 개인정보 처리방침, 개별 모델 카드와 라이선스를 확인하십시오.

### SiliconFlow

중국 본토의 모델 애그리게이터 및 추론 플랫폼으로 사용될 수 있습니다.

- [SiliconFlow 공식 사이트](https://siliconflow.cn/)

개인정보 처리방침, 서비스 약관, 모델 서비스 조건, 상위 모델 제공자의 규칙을 확인하십시오.

### OpenRouter

전 세계 모델 애그리게이터로 사용될 수 있으며, 상위 모델 제공자가 입력과 출력을 독립적으로 처리할 수도 있습니다.

- [OpenRouter Privacy Policy](https://openrouter.ai/privacy)
- [OpenRouter Terms of Service](https://openrouter.ai/terms)

제공자 및 데이터 관련 페이지와 선택한 상위 모델 제공자의 정책도 확인하십시오.

### Ollama

주로 로컬 또는 로컬 네트워크의 모델 서비스에 사용됩니다. 공식 클라우드나 원격 호스팅 서비스에 연결하는 경우 해당 정책을 별도로 확인하십시오.

- [Ollama Privacy Policy](https://ollama.com/privacy)
- [Ollama Terms](https://ollama.com/terms)

### LM Studio

주로 로컬 데스크톱 또는 로컬 네트워크의 모델 서비스에 사용됩니다. 원격 다운로드, 계정, 동기화 또는 호스팅 서비스를 사용하는 경우 해당 정책을 확인하십시오.

- [LM Studio Privacy](https://lmstudio.ai/privacy)
- [LM Studio Terms](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi에서 현재 선택할 수 있는 빠른 제공자 항목 중 하나로, Anthropic의 기본 Messages API로 연결됩니다. Claude는 OpenRouter, 기업 게이트웨이 또는 사용자 지정 엔드포인트를 통해 사용될 수도 있습니다.

- [Anthropic Privacy Policy](https://www.anthropic.com/legal/privacy)
- [Anthropic Terms and policies](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

Google 공식 API, Vertex AI, 애그리게이터 또는 기업 게이트웨이를 통해 사용될 수 있습니다.

- [Google Privacy Policy](https://policies.google.com/privacy)
- [Google Cloud Privacy Notice](https://cloud.google.com/terms/cloud-privacy-notice)
- [Google AI / Gemini API additional terms](https://ai.google.dev/terms)

### Mistral AI

Mistral 공식 API, 애그리게이터 또는 기업 게이트웨이를 통해 사용될 수 있습니다.

- [Mistral AI Legal Center](https://legal.mistral.ai/terms)
- [Mistral AI Privacy Policy](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

일반적으로 제3자 호스팅, 클라우드 사업자, 애그리게이터, 로컬 배포 또는 기업 게이트웨이를 통해 사용됩니다. Meta가 공개한 모델 라이선스는 호스팅 서비스의 개인정보 처리방침과 같지 않습니다.

- [Meta Privacy Policy](https://www.facebook.com/privacy/policy/)
- [Llama official site](https://www.llama.com/)

실제 호스트, 클라우드 사업자 또는 로컬 배포 운영자의 정책도 확인하십시오.

### xAI / Grok

공식 API, 애그리게이터 또는 기업 게이트웨이를 통해 사용될 수 있습니다.

- [xAI Privacy Policy](https://x.ai/legal/privacy-policy)
- [xAI Terms of Service](https://x.ai/legal/terms-of-service)

### Cohere

Cohere 공식 API, 애그리게이터 또는 기업 게이트웨이를 통해 사용될 수 있습니다.

- [Cohere Privacy Policy](https://cohere.com/privacy)
- [Cohere Terms of Use](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

모델 다운로드, 호스팅, 추론, Spaces 또는 제3자 inference provider의 창구로 사용될 수 있습니다.

- [Hugging Face Privacy Policy](https://huggingface.co/privacy)
- [Hugging Face Terms of Service](https://huggingface.co/terms-of-service)

실제 inference provider와 개별 모델의 라이선스도 확인하십시오.

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

이러한 서비스는 사용자 지정 엔드포인트, 애그리게이터, SDK, 기업 게이트웨이 또는 상위 호스트를 통해 사용될 수 있습니다.

- [Together AI Privacy](https://www.together.ai/privacy)
- [Fireworks AI Privacy](https://fireworks.ai/privacy)
- [Groq Privacy Policy](https://groq.com/privacy-policy/)
- [Replicate Privacy](https://replicate.com/privacy)
- [Perplexity Privacy Policy](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs Privacy Policy](https://www.ai21.com/privacy-policy)

### iFlytek Spark / Huawei Cloud Pangu / SenseTime / Baichuan / 01.AI / Xiaomi / Meituan 및 기타 제공자

사용자 지정 엔드포인트, 클라우드 마켓플레이스, 기업 게이트웨이, 로컬 배포 또는 애그리게이터를 통해 사용될 수 있습니다. 적용되는 규칙은 계정, 지역, 서비스 형태, 호스트에 따라 다릅니다.

- [iFlytek 오픈 플랫폼 개인정보 처리방침](https://www.xfyun.cn/doc/policy/privacy.html)
- [Huawei Cloud 개인정보 보호](https://www.huaweicloud.com/declaration/sa_prp.html)
- [Xiaomi 개인정보 처리방침](https://privacy.mi.com/all/zh_CN/)

Meituan LongCat, Baichuan, 01.AI, SenseTime 등의 서비스는 각 제공자의 공식 사이트, 오픈 플랫폼 또는 모델 서비스 콘솔에 표시되는 최신 정책을 따르십시오.

위에 나열되지 않은 서비스에도 같은 원칙을 적용하십시오. 엔드포인트 소유자, 서비스 운영 주체, 상위 제공자, 적용 지역, 로그 및 학습 정책, 삭제와 내보내기 방법, 비용, 컴플라이언스상의 제한을 확인해야 합니다.

## 10. 사용자 확인

1. Palmi가 로컬 처리를 우선하는 Agent 앱이자 모델 연결을 위한 인터페이스이며, 현재 설계에서는 채팅 내용, 작업 공간 파일, 첨부 파일 또는 API 키를 Palmi가 운영하는 중앙 서버 데이터베이스에 두지 않는다는 것을 이해합니다.
2. 제3자 모델, 애그리게이터, 검색 소스, 시스템 서비스, 기업 게이트웨이, 로컬 또는 원격 자체 호스팅 엔드포인트, 기타 도구를 설정하거나 사용할 때 내가 보내기로 선택한 내용과 필요한 메타데이터가 해당 서비스에 의해 처리될 수 있음을 이해합니다.
3. 제3자의 데이터 보관, 학습 활용, 상위 전달, 국외 이전, 삭제 요청, 계정 보안, 비용, 분쟁 처리는 해당 제3자의 최신 정책과 나와 그 제3자 사이의 계약을 따른다는 것을 이해합니다.
4. 개인정보, 기업 자료, 고객 데이터, 파일, 이미지, 코드 또는 기타 내용은 충분한 권리, 권한, 컴플라이언스 근거가 있을 때에만 제출하고, 위험이 높은 상황에서는 사람의 검토를 거치겠습니다.
5. 이 고지에 동의하지 않거나 선택한 제공자의 정책을 확인하지 않은 경우, 모델 설정을 중단하거나 이전 단계로 돌아가 선택을 변경할 수 있습니다.

이 문서는 제품 내 사용자 고지와 운영상의 확인을 위한 것입니다. 특정 사용자, 조직, 산업 또는 법역을 위한 개별적인 법률 자문이 아닙니다. 정식 출시, App Store 제출, 상업적 출시 또는 규제 대상 산업에서의 사용 전에는 관련 법역의 자격 있는 전문가의 검토를 받을 것을 권장합니다.
