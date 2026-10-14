import { MINI_PROGRAM_RELEASE_NOTES, MINI_PROGRAM_VERSION } from '../../config';

const releases = [
  {
    version: MINI_PROGRAM_VERSION,
    date: '开发中 · 暂未上线',
    notes: MINI_PROGRAM_RELEASE_NOTES,
  },
];

Page({ data: { releases } });
