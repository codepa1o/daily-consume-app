import { API_BASE_URL } from '../config';
import { Utf8Decoder } from './utf8';

const sessionKey = 'daily_consume_session';
const accountKey = 'daily_consume_account';
const privacyConsentKey = 'daily_consume_privacy_v1';

export interface Account {
  id: number;
  username: string;
  nickname: string;
  gender: 'unset' | 'male' | 'female';
  age: number | null;
  created_at: string;
}

export interface LoginResponse {
  token: string;
  user: Account;
  expires_at: string;
}

export interface WechatStatus {
  configured: boolean;
  bound: boolean;
}

export class ApiError extends Error {
  constructor(message: string, readonly statusCode = 0) {
    super(message);
  }
}

export type StreamEvent = (name: string, data: Record<string, unknown>) => void;
export type AbortableTask = { abort: () => void };
export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

export function getToken(): string {
  return wx.getStorageSync<string>(sessionKey) || '';
}

export function getAccount(): Account | null {
  return wx.getStorageSync<Account | null>(accountKey) || null;
}

export function saveSession(session: LoginResponse): void {
  wx.setStorageSync(sessionKey, session.token);
  saveAccount(session.user);
}

export function saveAccount(account: Account): void {
  const profile: Account = {
    id: account.id,
    username: account.username,
    nickname: account.nickname,
    gender: account.gender,
    age: account.age,
    created_at: account.created_at,
  };
  wx.setStorageSync(accountKey, profile);
}

export function clearSession(): void {
  wx.removeStorageSync(sessionKey);
  wx.removeStorageSync(accountKey);
}

export function hasPrivacyConsent(): boolean {
  return wx.getStorageSync<boolean>(privacyConsentKey) === true;
}

export function acceptPrivacyConsent(accepted: boolean): void {
  if (accepted) wx.setStorageSync(privacyConsentKey, true);
  else wx.removeStorageSync(privacyConsentKey);
}

export function loginWithWechat(): Promise<LoginResponse> {
  return wechatCode<LoginResponse>('auth/wechat/login', false);
}

export async function bindWechat(): Promise<void> {
  await wechatCode('auth/wechat/bind');
}

function wechatCode<T>(path: string, authenticated = true): Promise<T> {
  return new Promise((resolve, reject) => {
    wx.login({
      success(result) {
        if (!result.code) {
          reject(new ApiError('无法获取微信登录凭证，请重试'));
          return;
        }
        request<T>('POST', path, { code: result.code }, authenticated)
          .then(resolve, reject);
      },
      fail() {
        reject(new ApiError('微信登录失败，请重试'));
      },
    });
  });
}

export function request<T>(
  method: HttpMethod,
  path: string,
  data?: Record<string, unknown>,
  authenticated = true,
  query?: Record<string, string>,
): Promise<T> {
  if (authenticated && !hasPrivacyConsent()) return Promise.reject(new ApiError('请先阅读并同意隐私保护指引'));
  if (!API_BASE_URL.startsWith('https://')) {
    return Promise.reject(new ApiError('请先在 config.ts 中配置 HTTPS API 地址'));
  }

  const headers: Record<string, string> = { Accept: 'application/json' };
  const token = getToken();
  if (authenticated && token) headers.Authorization = `Bearer ${token}`;
  const queryString = query
    ? Object.entries(query).map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join('&')
    : '';
  const url = `${API_BASE_URL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}${queryString ? `?${queryString}` : ''}`;

  return new Promise((resolve, reject) => {
    wx.request({
      url,
      method,
      data,
      header: headers,
      success(response) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          resolve(response.data as T);
          return;
        }

        if (response.statusCode === 401 && authenticated) clearSession();
        const body = response.data as { detail?: unknown } | undefined;
        const message = typeof body?.detail === 'string'
          ? body.detail
          : response.statusCode === 429
            ? '操作过于频繁，请稍后重试'
            : '服务器暂时不可用，请重试';
        reject(new ApiError(message, response.statusCode));
      },
      fail() {
        reject(new ApiError('无法连接服务器，请检查网络后重试'));
      },
    });
  });
}

export function streamRequest(path: string, body: Record<string, unknown>, onEvent: StreamEvent, onTask?: (task: AbortableTask) => void): Promise<void> {
  if (!hasPrivacyConsent()) return Promise.reject(new ApiError('请先阅读并同意隐私保护指引'));
  if (!API_BASE_URL.startsWith('https://')) return Promise.reject(new ApiError('请先在 config.ts 中配置 HTTPS API 地址'));
  const token = getToken();
  if (!token) return Promise.reject(new ApiError('请先登录', 401));
  let buffer = '';
  let eventName = 'message';
  let dataLines: string[] = [];
  const decoder = new Utf8Decoder();
  let receivedChunk = false;
  const consume = (block: string) => {
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) eventName = line.slice(6).trim();
      else if (line.startsWith('data:')) dataLines.push(line.slice(5).trimStart());
    }
    if (dataLines.length) {
      const data = JSON.parse(dataLines.join('\n')) as Record<string, unknown>;
      onEvent(eventName, data);
    }
    eventName = 'message';
    dataLines = [];
  };
  return new Promise((resolve, reject) => {
    let finished = false;
    const fail = (error: Error) => {
      if (finished) return;
      finished = true;
      reject(error);
    };
    const task = wx.request<ArrayBuffer>({
      url: `${API_BASE_URL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`,
      method: 'POST',
      data: body,
      responseType: 'arraybuffer',
      enableChunked: true,
      timeout: 120000,
      header: {
        Accept: 'text/event-stream',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      success(response) {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (response.statusCode === 401) clearSession();
          const bytes = response.data instanceof ArrayBuffer ? response.data : new ArrayBuffer(0);
          const text = decoder.decode(bytes);
          let detail = '';
          try { detail = (JSON.parse(text) as { detail?: string }).detail ?? ''; } catch (_) {}
          fail(new ApiError(detail || '请求失败，请重试', response.statusCode));
          return;
        }
        try {
          if (!receivedChunk && response.data instanceof ArrayBuffer) buffer = decoder.decode(response.data);
          else buffer += decoder.decode();
          if (buffer.trim()) consume(buffer.trim());
          finished = true;
          resolve();
        } catch (_) { fail(new ApiError('服务器返回的流式数据格式无效')); }
      },
      fail() { fail(new ApiError('无法连接服务器，请检查网络后重试')); },
    });
    onTask?.(task);
    task.onChunkReceived(({ data }) => {
      try {
        receivedChunk = true;
        buffer += decoder.decode(data, { stream: true }).replace(/\r/g, '');
        let boundary = buffer.indexOf('\n\n');
        while (boundary >= 0) {
          const block = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          if (block) consume(block);
          boundary = buffer.indexOf('\n\n');
        }
      } catch (_) { fail(new ApiError('服务器返回的流式数据格式无效')); task.abort(); }
    });
  });
}

export function requestBinary<T extends Record<string, unknown>>(path: string, body: T): Promise<ArrayBuffer> {
  if (!hasPrivacyConsent()) return Promise.reject(new ApiError('请先阅读并同意隐私保护指引'));
  if (!API_BASE_URL.startsWith('https://')) return Promise.reject(new ApiError('请先在 config.ts 中配置 HTTPS API 地址'));
  const token = getToken();
  if (!token) return Promise.reject(new ApiError('请先登录', 401));
  return new Promise((resolve, reject) => {
    wx.request<ArrayBuffer>({
      url: `${API_BASE_URL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`,
      method: 'POST', data: body, responseType: 'arraybuffer', timeout: 120000,
      header: { Accept: 'application/pdf', 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      success(response) {
        if (response.statusCode >= 200 && response.statusCode < 300 && response.data instanceof ArrayBuffer) {
          resolve(response.data);
          return;
        }
        if (response.statusCode === 401) clearSession();
        let detail = '';
        if (response.data instanceof ArrayBuffer) {
          try { detail = (JSON.parse(new Utf8Decoder().decode(response.data)) as { detail?: string }).detail ?? ''; } catch (_) {}
        }
        reject(new ApiError(detail || '文件下载失败，请重试', response.statusCode));
      },
      fail() { reject(new ApiError('无法下载文件，请检查网络后重试')); },
    });
  });
}

export function downloadFile(path: string, query?: Record<string, string>): Promise<string> {
  if (!hasPrivacyConsent()) return Promise.reject(new ApiError('请先阅读并同意隐私保护指引'));
  if (!API_BASE_URL.startsWith('https://')) return Promise.reject(new ApiError('请先在 config.ts 中配置 HTTPS API 地址'));
  const token = getToken();
  if (!token) return Promise.reject(new ApiError('请先登录', 401));
  const suffix = query ? Object.entries(query).map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join('&') : '';
  const url = `${API_BASE_URL.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}${suffix ? `?${suffix}` : ''}`;
  return new Promise((resolve, reject) => {
    wx.downloadFile({
      url,
      header: { Authorization: `Bearer ${token}` },
      success(result) {
        if (result.statusCode === 200 && result.tempFilePath) resolve(result.tempFilePath);
        else reject(new ApiError('文件下载失败，请重试', result.statusCode));
      },
      fail() { reject(new ApiError('无法下载文件，请检查网络后重试')); },
    });
  });
}
