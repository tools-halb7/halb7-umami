'use client';
import { useMemo, useState } from 'react';
import { Badge, Button, Column, Grid, Row, Text, TextField } from '@umami/react-zen';
import { PageBody } from '@/components/common/PageBody';
import { PageHeader } from '@/components/common/PageHeader';
import { Panel } from '@/components/common/Panel';
import { useLoginQuery, useUserWebsitesQuery } from '@/components/hooks';
import { Tag } from '@/components/icons';

const SOURCE_PRESETS = [
  'newsletter',
  'instagram',
  'facebook',
  'google',
  'linkedin',
  'whatsapp',
  'flyer',
  'qr',
];
const MEDIUM_PRESETS = ['email', 'social', 'cpc', 'print', 'qr', 'referral'];

interface UtmField {
  key: 'source' | 'medium' | 'campaign' | 'content' | 'term';
  param: string;
  label: string;
  placeholder: string;
  required: boolean;
  presets?: string[];
}

const UTM_FIELDS: UtmField[] = [
  {
    key: 'source',
    param: 'utm_source',
    label: 'Quelle',
    placeholder: 'newsletter',
    required: true,
    presets: SOURCE_PRESETS,
  },
  {
    key: 'medium',
    param: 'utm_medium',
    label: 'Medium',
    placeholder: 'email',
    required: true,
    presets: MEDIUM_PRESETS,
  },
  {
    key: 'campaign',
    param: 'utm_campaign',
    label: 'Kampagne',
    placeholder: 'sommer2026',
    required: true,
  },
  {
    key: 'content',
    param: 'utm_content',
    label: 'Inhalt / Variante',
    placeholder: 'header-button',
    required: false,
  },
  {
    key: 'term',
    param: 'utm_term',
    label: 'Keyword',
    placeholder: 'catering-telfs',
    required: false,
  },
];

function slugify(value: string) {
  return value
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '-')
    .replace(/[^a-z0-9\-_.]/g, '')
    .replace(/-+/g, '-')
    .replace(/^[-_.]+|[-_.]+$/g, '');
}

function normalizeBase(value: string) {
  const trimmed = value.trim();
  if (!trimmed) {
    return '';
  }
  return /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
}

interface HistoryEntry {
  url: string;
  campaign: string;
  source: string;
  medium: string;
  ts: number;
}

const HISTORY_KEY = 'halb7-utm-history';

function loadHistory(): HistoryEntry[] {
  try {
    const raw = localStorage.getItem(HISTORY_KEY);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveHistory(items: HistoryEntry[]) {
  try {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(items.slice(0, 20)));
  } catch {
    // localStorage unavailable (private mode etc.) — history simply won't persist
  }
}

export function UtmPage() {
  const { user } = useLoginQuery();
  const { data } = useUserWebsitesQuery({ userId: user?.id }, { pageSize: 50 });
  const websites = ((data?.data || []) as { id: string; name: string; domain?: string }[]).filter(
    w => !!w.domain,
  );

  const [base, setBase] = useState('');
  const [values, setValues] = useState<Record<string, string>>({
    source: '',
    medium: '',
    campaign: '',
    content: '',
    term: '',
  });
  const [history, setHistory] = useState<HistoryEntry[]>(() =>
    typeof window !== 'undefined' ? loadHistory() : [],
  );

  const normalizedValues = useMemo(() => {
    const out: Record<string, string> = {};
    UTM_FIELDS.forEach(f => {
      out[f.key] = slugify(values[f.key] || '');
    });
    return out;
  }, [values]);

  const parsedBase = useMemo(() => {
    const normalized = normalizeBase(base);
    if (!normalized) {
      return null;
    }
    try {
      return new URL(normalized);
    } catch {
      return null;
    }
  }, [base]);

  const fullUrl = useMemo(() => {
    if (!parsedBase) {
      return '';
    }
    const url = new URL(parsedBase.toString());
    UTM_FIELDS.forEach(f => {
      if (normalizedValues[f.key]) {
        url.searchParams.set(f.param, normalizedValues[f.key]);
      }
    });
    return url.toString();
  }, [parsedBase, normalizedValues]);

  const missing = UTM_FIELDS.filter(f => f.required && !normalizedValues[f.key]);
  const isReady = !!parsedBase && missing.length === 0;

  const handleFieldChange = (key: string, val: string) => {
    setValues(prev => ({ ...prev, [key]: val }));
  };

  const handlePickWebsite = (domain: string) => {
    setBase(`https://${domain}/`);
  };

  const handleSave = () => {
    if (!isReady) {
      return;
    }
    const entry: HistoryEntry = {
      url: fullUrl,
      campaign: normalizedValues.campaign,
      source: normalizedValues.source,
      medium: normalizedValues.medium,
      ts: Date.now(),
    };
    if (history[0]?.url === entry.url) {
      return;
    }
    const next = [entry, ...history];
    setHistory(next);
    saveHistory(next);
  };

  return (
    <PageBody>
      <PageHeader
        title="UTM-Baukasten"
        description="Baut normalisierte Tracking-Links. Umami erfasst utm_* Parameter automatisch."
        icon={<Tag />}
      />

      <Grid columns={{ base: '1fr', lg: '1fr 400px' }} gap="6" alignItems="start">
        <Column gap="6">
          <Panel title="Ziel">
            <TextField
              label="Ziel-URL"
              placeholder="https://marktkueche-telfs.at/"
              value={base}
              onChange={setBase}
              autoComplete="off"
            />
            {websites.length > 0 && (
              <Row gap="2" style={{ flexWrap: 'wrap' }}>
                {websites.map(w => (
                  <Button
                    key={w.id}
                    size="xs"
                    variant="outline"
                    onPress={() => handlePickWebsite(w.domain as string)}
                  >
                    {w.name}
                  </Button>
                ))}
              </Row>
            )}
          </Panel>

          <Panel title="Kampagnen-Parameter">
            <Column gap="5">
              {UTM_FIELDS.map(f => (
                <Column key={f.key} gap="2">
                  <TextField
                    label={`${f.label} — ${f.param}${f.required ? ' *' : ''}`}
                    placeholder={f.placeholder}
                    value={values[f.key]}
                    onChange={(v: string) => handleFieldChange(f.key, v)}
                    autoComplete="off"
                  />
                  {f.presets && (
                    <Row gap="2" style={{ flexWrap: 'wrap' }}>
                      {f.presets.map(p => (
                        <Button
                          key={p}
                          size="xs"
                          variant="quiet"
                          onPress={() => handleFieldChange(f.key, p)}
                        >
                          {p}
                        </Button>
                      ))}
                    </Row>
                  )}
                  {values[f.key] &&
                    normalizedValues[f.key] &&
                    values[f.key].toLowerCase() !== normalizedValues[f.key] && (
                      <Text size="xs" color="muted">
                        wird zu: {normalizedValues[f.key]}
                      </Text>
                    )}
                </Column>
              ))}
            </Column>
          </Panel>
        </Column>

        <Column gap="6" style={{ position: 'sticky', top: 16 }}>
          <Panel title="Dein Link">
            <Column gap="4">
              <Row justifyContent="space-between" alignItems="center">
                <Text weight="bold" size="sm">
                  Vorschau
                </Text>
                <Badge variant={isReady ? 'success' : 'warning'}>
                  {isReady
                    ? 'Bereit'
                    : !parsedBase
                      ? 'Ziel-URL fehlt'
                      : `Fehlt: ${missing.map(m => m.label).join(', ')}`}
                </Badge>
              </Row>
              <TextField
                isReadOnly
                allowCopy
                asTextArea
                value={fullUrl || 'Ziel-URL eingeben, dann Quelle · Medium · Kampagne …'}
                style={{ minHeight: 90 }}
              />
              <Button
                variant="primary"
                isDisabled={!isReady}
                onPress={handleSave}
                style={{ width: '100%' }}
              >
                Zum Verlauf hinzufügen
              </Button>
            </Column>
          </Panel>

          <Panel title="Zuletzt erstellt">
            {history.length === 0 ? (
              <Text color="muted" size="sm">
                Noch nichts erstellt.
              </Text>
            ) : (
              <Column gap="4">
                {history.slice(0, 8).map((h, i) => (
                  <Column key={i} gap="1">
                    <Text weight="bold" size="sm">
                      {h.campaign || '(ohne Kampagne)'}
                    </Text>
                    <Text size="xs" color="muted">
                      {h.source} · {h.medium}
                    </Text>
                  </Column>
                ))}
              </Column>
            )}
          </Panel>
        </Column>
      </Grid>
    </PageBody>
  );
}
