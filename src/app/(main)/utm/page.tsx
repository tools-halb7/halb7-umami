import type { Metadata } from 'next';
import { UtmPage } from './UtmPage';

export default function () {
  return <UtmPage />;
}

export const metadata: Metadata = {
  title: 'UTM-Baukasten',
};
