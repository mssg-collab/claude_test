const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        '^lightning/refresh$': '<rootDir>/jest-mocks/lightning/refresh'
    },
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver']
};
