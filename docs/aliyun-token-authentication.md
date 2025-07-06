# Aliyun Token Authentication Implementation

## Overview

The Aliyun speech service uses a two-step authentication process:
1. **Token Request**: Use AccessKeyId + AccessKeySecret to obtain a temporary token
2. **Service Request**: Use the token + AppKey to access transcription services

## Required Parameters

### For Token Request (需要三个参数)
- **AccessKeyId**: 阿里云访问密钥 ID
- **AccessKeySecret**: 阿里云访问密钥秘钥 (用于签名生成)
- **AppKey**: 语音服务应用密钥 (用于转录接口)

## Token Request Authentication Protocol

### API Endpoint
```
POST http://nls-meta.cn-shanghai.aliyuncs.com/
```

### Required Parameters
```
Action=CreateToken
Version=2019-02-28
Format=JSON
RegionId=cn-shanghai
AccessKeyId={your-access-key-id}
SignatureMethod=HMAC-SHA1
SignatureVersion=1.0
Timestamp={ISO8601-UTC-timestamp}
SignatureNonce={unique-uuid}
Signature={calculated-signature}
```

### Signature Generation Algorithm

1. **Canonicalize Parameters**
   - Sort all parameters alphabetically by key
   - URL-encode both keys and values
   - Join as `key=value&key=value...`

2. **Create String-to-Sign**
   ```
   HTTP_METHOD + "&" + 
   URL_encode("/") + "&" + 
   URL_encode(canonical_query_string)
   ```

3. **Calculate Signature**
   ```
   signature = HMAC-SHA1(string_to_sign, access_key_secret + "&")
   ```

4. **URL Encode Signature**
   - Final signature must be URL-encoded before sending

### Example Request Format
```
POST / HTTP/1.1
Host: nls-meta.cn-shanghai.aliyuncs.com
Content-Type: application/x-www-form-urlencoded

SignatureVersion=1.0&Action=CreateToken&Format=JSON&SignatureNonce=8d1e6a7a-f44e-40d5-aedb-fe4a1c80f434&Version=2019-02-28&AccessKeyId=LTAF3sAA****&Signature=oT8A8RgvFE1tMD%2B3hDbGuoMQSi8%3D&SignatureMethod=HMAC-SHA1&RegionId=cn-shanghai&Timestamp=2019-03-25T09%3A07%3A52Z
```

## Response Format

### Success Response
```json
{
  "RequestId": "F1B3D2C4-891D-40BD-9CB0-B5C8B3A9A11C",
  "NlsRequestId": "F1B3D2C4-891D-40BD-9CB0-B5C8B3A9A11C",
  "Token": {
    "Id": "f00dcbe4143f49d2b70c08ab20b1****",
    "ExpireTime": 1553502472,
    "UserId": "1234567890"
  }
}
```

### Error Response
```json
{
  "RequestId": "F1B3D2C4-891D-40BD-9CB0-B5C8B3A9A11C",
  "Message": "signature does not conform to standards. server string to sign is:POST...",
  "Code": "SignatureDoesNotMatch"
}
```

## Implementation Notes

### Security Best Practices
- Never log AccessKeySecret in plaintext
- Use secure storage for credentials
- Implement proper error handling for authentication failures
- Cache tokens appropriately (expire 5 minutes before actual expiration)

### Error Handling
- **SignatureDoesNotMatch**: Check signature generation algorithm
- **IncompleteSignature**: Verify all required parameters are present
- **InvalidAccessKeyId**: Verify AccessKeyId is correct
- **InvalidTimeStamp**: Ensure timestamp is in ISO8601 UTC format

### Token Management
- Tokens are valid for 24 hours
- Implement automatic refresh 5 minutes before expiration
- Handle token refresh failures gracefully
- Cache tokens in secure storage

## Testing

### Connection Test Flow
1. Generate signature with current timestamp
2. Send token request to Aliyun API
3. Verify response contains valid token
4. Cache token for subsequent requests

### Validation Points
- Signature generation correctness
- Parameter encoding accuracy
- Timestamp format compliance
- Response parsing reliability

## Integration with Transcription Services

Once token is obtained, use it with AppKey for transcription requests:

### Real-time Transcription
```
WebSocket URL: wss://nls-gateway.cn-shanghai.aliyuncs.com/ws/v1
Headers: 
  - X-NLS-Token: {obtained-token}
  - appkey: {your-app-key}
```

### File Transcription
```
POST https://nls-filetrans.cn-shanghai.aliyuncs.com/filetrans/v1/SubmitTask
Headers:
  - X-NLS-Token: {obtained-token}
  - appkey: {your-app-key}
```

## References

- [Official Aliyun Token Documentation](https://help.aliyun.com/zh/isi/getting-started/use-http-or-https-to-obtain-an-access-token)
- [Aliyun Signature Algorithm](https://help.aliyun.com/document_detail/315526.html)
- [Speech Service API Reference](https://help.aliyun.com/document_detail/84435.html)