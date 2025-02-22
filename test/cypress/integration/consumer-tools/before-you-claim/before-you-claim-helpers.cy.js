import retirementAPIResponse from '../../../fixtures/retirement-api.json';

export class BeforeYouClaim {
  open() {
    cy.visit( '/consumer-tools/retirement/before-you-claim/' );
  }

  setBirthDate( month, day, year ) {
    cy.get( '#bd-month' ).type( month );
    cy.get( '#bd-day' ).type( day );
    cy.get( '#bd-year' ).type( year );
  }

  setHighestAnnualSalary( salary ) {
    cy.get( '#salary-input' ).type( salary );
  }

  interceptRetirementAPIRequests() {
    cy.intercept(
      {
        url: '/consumer-tools/retirement/retirement-api/estimator/**'
      },
      request => {
        request.reply( retirementAPIResponse );
      }
    ).as( 'retirementAPIResponse' );
  }

  getEstimate() {
    cy.get( '#get-your-estimates' ).click();
  }

  claimGraph() {
    return cy.get( '#claim-canvas' );
  }

  setLanguageToSpanish() {
    return cy.get( '.content-l' ).within( () => {
      cy.get( 'a' ).first().click();
    } );
  }
}
