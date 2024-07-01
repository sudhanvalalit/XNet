!***************************************************************************************************
! xnet_ffn.f90 10/18/17
! This file contains reaction data structures for Fuller, Fowler, Neuman (FFN; 1982,1985) formated
! weak reactions and routines to read the data and calculate the reaction rates.
!***************************************************************************************************

Module xnet_ffn
  !-------------------------------------------------------------------------------------------------
  ! This module contains the data to calculate FFN formatted weak reactions.
  !-------------------------------------------------------------------------------------------------
  Use xnet_types, Only: dp
  Implicit None
  Integer, Parameter  :: nt9grid = 13             ! Number of temperature grid points per rate
  Integer, Parameter  :: nenegrid = 11            ! Number of electron density grid points per rate
  Integer, Parameter  :: ngrid = nt9grid*nenegrid ! Total number of grid points per rate
  Real(dp), Parameter :: t9grid(nt9grid) = &      ! Temperature grid for FFN rate data
    & (/ 0.01, 0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0, 30.0, 100.0 /)
  Real(dp), Parameter :: enegrid(nenegrid) = &    ! Electron density grid for FFN rate data
    & (/ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0 /)
  Real(dp), Allocatable :: ffn_ec(:,:), ffn_beta(:,:) ! dim(nffn,ngrid)
  Real(dp), Allocatable :: ffnsum(:,:), ffnenu(:,:)   ! dim(nffn,ngrid)
  Real(dp), Allocatable :: ffn_qval(:)
  Integer, Allocatable :: has_logft(:)

Contains

  Subroutine read_ffn_data(nffn,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine decides whether to call the standard read or the logft table read
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: iweak0
    Implicit None

    ! Input variables
    Integer, Intent(in)  :: nffn
    Character(*), Intent(in) :: data_dir

    Allocate (has_logft(nffn))
    has_logft = 0

    If ( abs(iweak0) == 2 ) Then  ! Allows to use -2 for weak interactions only
      Call read_ffn_data_logft(nffn,data_dir)
    Else
      Call read_ffn_data_table(nffn,data_dir)
    EndIf

  End Subroutine read_ffn_data

  Subroutine read_ffn_data_table(nffn,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine allocates and loads the data structures for FFN reaction rates.
    !-----------------------------------------------------------------------------------------------
    Implicit None

    ! Input variables
    Integer, Intent(in)  :: nffn
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: i, j, lun_ffn

    Allocate (ffnsum(nffn,ngrid),ffnenu(nffn,ngrid))
    ffnsum = 0.0
    ffnenu = 0.0

    Open(newunit=lun_ffn, file=trim(data_dir)//"/netweak", status='old', action='read')
    Do i = 1, nffn
      Read(lun_ffn,*)
      Read(lun_ffn,*) (ffnsum(i,j), ffnenu(i,j), j=1,ngrid)
    EndDo
    Close(lun_ffn)

    Return
  End Subroutine read_ffn_data_table

  Subroutine read_ffn_data_logft(nffn,data_dir)
    !-----------------------------------------------------------------------------------------------
    ! This routine allocates and loads the data structures for FFN reaction rates.
    !-----------------------------------------------------------------------------------------------
    Use xnet_controls, Only: lun_diag
    Implicit None

    ! Input variables
    Integer, Intent(in)  :: nffn
    Character(*), Intent(in) :: data_dir

    ! Local variables
    Integer :: i, j, lun_ffn
    Character(6) :: nuc1,nuc2
    Character(3) :: desc
    Real(dp) :: qval_in

    Allocate (ffnsum(nffn,ngrid),ffnenu(nffn,ngrid))
    Allocate (ffn_ec(nffn,ngrid),ffn_beta(nffn,ngrid))
    Allocate (ffn_qval(nffn))
    ffnsum = 0.0
    ffnenu = 0.0
    ffn_ec = 0.0
    ffn_beta = 0.0
    ffn_qval = 0.0

    Open(newunit=lun_ffn, file=trim(data_dir)//"/netweak", status='old')
    Do i = 1, nffn
      Read(lun_ffn,*)  nuc1, nuc2,desc, ffn_qval(i)

      If ( desc == 'ft+' ) Then
        has_logft(i) = 2 ! positron capture
      ElseIf ( desc == 'ft-' ) Then
        has_logft(i) = 1 ! electron capture
      Else
        has_logft(i) = 0
      EndIf
      Read(lun_ffn,*) (ffn_beta(i,j),ffn_ec(i,j),ffnsum(i,j), ffnenu(i,j), j=1,ngrid)

    ! Read logft, beta-decay rate and sum.
    EndDo
    Close(lun_ffn)

    Where (ffn_ec < -30d0)
      ffn_ec = 99.d0
    End Where

    Return
  End Subroutine read_ffn_data_logft

  Subroutine ffn_rate(nffn,t9,ene,rf,dlnrfdt9,mask_in)
    !-----------------------------------------------------------------------------------------------
    ! This routine calculates the reaction rates for FFN weak rates
    !-----------------------------------------------------------------------------------------------
    Use xnet_constants, Only: ln_2, ln_10, bok, m_e
    Use xnet_controls, Only: iheat, nzevolve, zb_lo, zb_hi, lzactive
    Use xnet_conditions, Only: etae
    Use xnet_types, Only: dp
    Use xnet_controls, Only: lun_diag, idiag

    Implicit None

    ! Input variables
    Integer, Intent(in)  :: nffn              ! Number of FFN rates
    Real(dp), Intent(in) :: t9(nzevolve)      ! Temperature [GK]
    Real(dp), Intent(in) :: ene(zb_lo:zb_hi)  ! Electron Density [g cm^{-3}]

    ! Output variables
    Real(dp), Intent(out) :: rf(nffn,zb_lo:zb_hi)       ! Temperature and density dependent FFN rates
    Real(dp), Intent(out) :: dlnrfdt9(nffn,zb_lo:zb_hi) ! Temperature and density dependent log FFN rate derivatives

    ! Optional variables
    Logical, Optional, Target, Intent(in) :: mask_in(zb_lo:zb_hi)

    ! Local variables
    Real(dp), Parameter :: lrfmin = -30.0, rfmin=1d-30
    Real(dp) :: r1, r2, dr1, dr2, dr1_ec, dr2_ec
    Real(dp) :: rf_beta,rf_ec, phasei, cheme, dphase_dt
    Real(dp) :: enel, dt9, dene, rdt9, rdene, drbeta_dt,drec_dt
    Integer :: i,izb, k, le1, lt1, i1, i2, i3, i4
    Logical, Pointer :: mask(:)

    If ( present(mask_in) ) Then
      mask(zb_lo:) => mask_in
    Else
      mask(zb_lo:) => lzactive(zb_lo:zb_hi)
    EndIf
    If ( .not. any(mask) ) Return

    Do izb = zb_lo, zb_hi
      If ( mask(izb) ) Then

        ! Find the temperature grid point
        Do i = 1, nt9grid
          If ( t9(izb) <= t9grid(i) ) Exit
        EndDo
        lt1 = max(i-1,1)

        ! Find the density grid point (on log grid)
        enel = log10(ene(izb))
        le1 = max(int(enel),1)

        ! Bi-linear interpolation
        dt9 = t9grid(lt1+1) - t9grid(lt1)
        rdt9 = (t9(izb) - t9grid(lt1)) / dt9
        dene = enegrid(le1+1) - enegrid(le1)
        rdene = (enel - enegrid(le1)) / dene
        i1 = nt9grid*(le1-1) + lt1
        i2 = i1 + 1
        i3 = nt9grid*le1 + lt1
        i4 = i3 + 1

        cheme = etae(izb)*bok*t9(izb)+m_e
        Do k = 1, nffn

          If (has_logft(k) > 0) then

             ! Calculate phase space integral and derivative
             If ( has_logft(k) == 1 ) Then
               Call effphase(t9(izb),cheme,ffn_qval(k),phasei,dphase_dt)
             ElseIf ( has_logft(k) == 2 ) Then
               Call effphase(t9(izb),-cheme,ffn_qval(k),phasei,dphase_dt)
             Else
               ! TODO: move this out of the loop
               Write(*,*) "Problem in logft option. Should be 1 or 2, but is ",has_logft(k)
               Stop
             EndIf

             dr1_ec = ffn_ec(k,i2) - ffn_ec(k,i1)
             dr2_ec = ffn_ec(k,i4) - ffn_ec(k,i3)
             r1 = ffn_ec(k,i1) + rdt9*dr1_ec
             r2 = ffn_ec(k,i3) + rdt9*dr2_ec
             rf_ec = r1 + rdene*(r2 - r1) ! logft
             If ( phasei > rfmin .and. rf_ec > lrfmin ) then
               rf_ec = ln_2 * phasei / 10.0**rf_ec ! turn into rate
             Else
               rf_ec = 0.0
             EndIf

             dr1 = ffn_beta(k,i2) - ffn_beta(k,i1)
             dr2 = ffn_beta(k,i4) - ffn_beta(k,i3)
             r1 = ffn_beta(k,i1) + rdt9*dr1
             r2 = ffn_beta(k,i3) + rdt9*dr2
             rf_beta = r1 + rdene*(r2 - r1)
             If ( rf_beta > lrfmin ) Then
               rf_beta = 10.0**rf_beta
             Else
               rf_beta = 0.0
             EndIf

             rf(k,izb) = rf_beta + rf_ec

             If ( rf_beta < rfmin .and. rf_ec < rfmin ) Then
               rf(k,izb) = 0.0
               dlnrfdt9(k,izb) = 0.0
             Else
               ! Temperature derivative
               If (rf_ec < rfmin) Then
                  dlnrfdt9(k,izb) = ln_10 * ( rdene*dr2 + (1.0-rdene)*dr1 ) / dt9
               Else
                  drbeta_dt = rf_beta*ln_10 * ( rdene*dr2 + (1.0-rdene)*dr1 ) / dt9
                  drec_dt = rf_ec * ( -ln_10 * ( rdene*dr2_ec + (1.0-rdene)*dr1_ec ) / dt9 &
                    & + dphase_dt / phasei )
                  dlnrfdt9(k,izb) = (drbeta_dt+drec_dt)/rf(k,izb)
               EndIf

               If ( idiag >= 5 ) Then
                 Write(lun_diag,*) "FFN rate, deriv., phase space: ", &
                   & k,rf(k,izb),dlnrfdt9(k,izb),phasei
               EndIf

             EndIf
          Else
             dr1 = ffnsum(k,i2) - ffnsum(k,i1)
             dr2 = ffnsum(k,i4) - ffnsum(k,i3)
             r1 = ffnsum(k,i1) + rdt9*dr1
             r2 = ffnsum(k,i3) + rdt9*dr2
             rf(k,izb) = r1 + rdene*(r2 - r1)
             If ( rf(k,izb) < lrfmin ) Then
               rf(k,izb) = 0.0
               dlnrfdt9(k,izb) = 0.0
             Else
               rf(k,izb) = 10.0**rf(k,izb)
               dlnrfdt9(k,izb) = ln_10 * ( rdene*dr2 + (1.0-rdene)*dr1 ) / dt9
             EndIf
          EndIf
        EndDo
      EndIf
    EndDo

    Return
  End Subroutine ffn_rate

  Subroutine effphase(t9,chem,qec,phasei,dphaseidt9)
    !-----------------------------------------------------------------------------------------------
    ! Routine to calculate the electron/positron capture phase space factors and derivatives w.r.t.
    ! temperature based on a decomposition into FD integrals that can be evaluated very fast.
    !-----------------------------------------------------------------------------------------------
    Use xnet_constants, Only: m_e, bok
    Use xnet_types, Only: dp
    Use fd, Only: fd0h, fd2h, fd4h, fd6h, fd8h
    Implicit None

    ! Input variables
    Real(dp), Intent(in) :: t9, chem, qec

    ! Output variables
    Real(dp), Intent(out) :: phasei, dphaseidt9

    ! Local variables
    Real(dp) :: beta, zeta, tbe, eta, xi, factor, dfactordt9, phi, dphidt9
    Real(dp) :: fd0, fd1, fd2, fd3, fd4, df0_dt
    Real(dp) :: a0, a1, a2, a3, a4

    ! Define convenient variables
    beta = 1.0 / ( bok * t9 )
    factor = 1.0 / ( beta * m_e )**5
    dfactordt9 = 5.0 * factor / t9
    eta = chem * beta
    zeta = beta * qec

    ! In this case, when the q-value is effectively positive,
    ! the lower integration limit of the Fermi integrals
    ! is not equal to the energy-offset by the Q-value.
    If ( qec > -m_e ) Then

      tbe = beta * m_e
      xi  = eta - tbe

      ! Coefficients
      a4 = 1.0
      a3 = 4.0*tbe+ 2.0*zeta
      a2 = 6.0*tbe**2 + 6.0*tbe*zeta + zeta**2
      a1 = 4.0*tbe**3 + 6.0*tbe**2*zeta + 2.0*tbe*zeta**2
      a0 = tbe**4 + 2.0*tbe**3*zeta + tbe**2*zeta**2

      ! Fermi integrals
      fd4 = fd8h(xi)
      fd3 = fd6h(xi)
      fd2 = fd4h(xi)
      fd1 = fd2h(xi)
      fd0 = fd0h(xi)
      ! analytic derivative of fd0
      df0_dt = 1d0 / ( exp(-xi) + 1d0 )

      ! Phase space factor
      phi = ( a0*fd0 + a1*fd1 + a2*fd2 + a3*fd3 + a4*fd4 )

      ! Calculate the derivative w.r.t temperature
      ! The derivative of factor is included later
      dphidt9 = -1.0 / t9 * ( &
        &  (               4.0*xi*fd3  ) + &
        &  ( a3*(    fd3 + 3.0*xi*fd2) ) + &
        &  ( a2*(2.0*fd2 + 2.0*xi*fd1) ) + &
        &  ( a1*(3.0*fd1 +     xi*fd0) ) + &
        &  ( a0*(4.0*fd0 +     xi*df0_dt) ) )

    Else

      ! This is the more common electron capture rate with
      ! negative effective Q-value

      ! Fermi integrals
      xi  = eta + zeta
      fd4 = fd8h(xi)
      fd3 = fd6h(xi)
      fd2 = fd4h(xi)
      fd1 = fd2h(xi)

      ! Phase space factor
      phi = ( fd4 - 2.0*zeta*fd3 + zeta**2*fd2 )

      ! Calculate the derivative w.r.t temperature
      dphidt9 = -1.0 / t9 * &
        & (   4.0*xi*fd3 &
        &   - 2.0*zeta*fd3 &
        &   - 6.0*zeta*xi*fd2 &
        &   + 2.0*zeta**2 * fd2 &
        &   + 2.0*zeta**2 * xi*fd1 )

    EndIf

    ! Phase space factor and derivative
    phasei = factor * phi
    dphaseidt9 = phi*dfactordt9 + dphidt9*factor

    Return
  End Subroutine effphase

End Module xnet_ffn
