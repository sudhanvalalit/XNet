!***************************************************************************************************
! xnet_integrate_be.f90 10/18/17
! Backward Euler solver
!
! The routines in this file perform the Backward Euler time integration for the thermonuclear
! reaction network.
!***************************************************************************************************

Module xnet_integrate_be
  Implicit None

Contains

  Subroutine solve_be(kstep,its)
    !-----------------------------------------------------------------------------------------------
    ! This routine handles the potential failure of an individual Backward Euler step. Repeated calls
    ! to the BE step integrator are made with successivley smaller timesteps until success is achieved
    ! or ktsmx trials fail. The abundances are evolved using a Newton-Raphson iteration scheme to
    ! solve the equation (yt(i)-y(i))/tdel = ydot(i), where y(i) is the abundance at the beginning of
    ! the iteration, yt(i) is the trial abundance at the end of the timestep, ydot(i) is the time
    ! derivative of the trial abundance calculated from reaction rates and tdel is the timestep.
    !-----------------------------------------------------------------------------------------------
    Use xnet_abundances, Only: y, yo, yt, xext
    Use xnet_conditions, Only: t, to, tt, tdel, tdel_next, t9, t9o, t9t, rho, rhoo, rhot, &
      yeo, ye, yet, nt, nto, ntt, t9rhofind, tdelstart
    Use xnet_controls, Only: idiag, iheat, kitmx, kmon, ktot, lun_diag, lun_stdout, tdel_maxmult, &
      & szbatch, zb_lo, zb_hi
    Use xnet_integrate, Only: timestep
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_tstep
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep

    ! Input/Output variables
    Integer, Intent(inout) :: its(zb_lo:zb_hi) ! On input,  = 0 indicates active zone
                                               ! On output, = 1 if zone fails to converge

    ! Local variables
    Integer, Parameter :: ktsmx = 10
    Integer :: kts, izb, izone
    Integer :: inr(zb_lo:zb_hi)
    Integer :: mykts(zb_lo:zb_hi)
    Logical :: lzstep(zb_lo:zb_hi)

    start_timer = xnet_wtime()
    timer_tstep = timer_tstep - start_timer

    ! If the zone has previously converged or failed, do not iterate
    Do izb = zb_lo, zb_hi
      If ( its(izb) /= 0 ) Then
        inr(izb) = -1
        lzstep(izb) = .false.
      Else
        inr(izb) = 0
        lzstep(izb) = .true.
      EndIf
    EndDo

    !-----------------------------------------------------------------------------------------------
    ! For each trial timestep, tdel, the NR iteration is attempted.
    ! The possible results for a timestep are a converged set of yt or a failure to converge.
    ! If convergence fails, retry with the trial timestep reduced by tdel_maxmult.
    !-----------------------------------------------------------------------------------------------
    mykts = 0
    Do kts = 1, ktsmx

      ! Attempt Backward Euler integration over desired timestep
      Call step_be(kstep,inr)

      Do izb = zb_lo, zb_hi

        ! If integration fails, reset abundances, reduce timestep and retry.
        If ( inr(izb) == 0 ) Then
          tdel(izb) = tdel(izb) / tdel_maxmult
          tt(izb) = t(izb) + tdel(izb)
          yet(izb) = ye(izb)
          yt(:,izb) = y(:,izb)
          mykts(izb) = kts+1

          ! Record number of NR iterations
          If ( its(izb) == 0 ) Then
            kmon(2,izb) = kitmx + 1
            ktot(2,izb) = ktot(2,izb) + kitmx + 1
          EndIf

        ! If integration is successfull, flag the zone for removal from zone loop
        ElseIf ( inr(izb) > 0 ) Then
          mykts(izb) = kts

          ! Record number of NR iterations
          If ( its(izb) == 0 ) Then
            kmon(2,izb) = inr(izb)
            ktot(2,izb) = ktot(2,izb) + inr(izb)
          EndIf
        EndIf
      EndDo

      ! Reset temperature and density for failed integrations
      lzstep = ( inr == 0 )
      Call t9rhofind(kstep,tt,ntt,t9t,rhot,mask_in = lzstep)
      If ( iheat > 0 ) Then
        Do izb = zb_lo, zb_hi
          If ( inr(izb) == 0 ) Then
            t9t(izb) = t9(izb)
          EndIf
        EndDo
      EndIf

      ! For the last attempt, re-calculate timestep based on derivatives
      ! as is done for the first timestep.
      If ( kts == ktsmx-1 ) Then
        Do izb = zb_lo, zb_hi
          If ( inr(izb) == 0 ) Then
            tdel(izb) = 0.0
            tdelstart(izb) = 0.0
          EndIf
        EndDo
        Call timestep(kstep,mask_in = lzstep)
      EndIf

      ! Log the failed integration attempts
      If ( idiag >= 2 ) Then
        Do izb = zb_lo, zb_hi
          If ( inr(izb) == 0 ) Then
            izone = izb + szbatch - zb_lo
            Write(lun_diag,"(a,i5,i3,3es12.4)") 'BE TS Reduce',izone,kts,tt(izb),tdel(izb),tdel_maxmult
          EndIf
        EndDo
      EndIf

      ! Test if all zones have converged
      If ( .not. any( lzstep ) ) Exit
    EndDo

    ! Mark TS convergence only for zones which haven't previously failed or converged
    Do izb = zb_lo, zb_hi
      If ( inr(izb) > 0 ) Then
        nto(izb) = nt(izb)
        nt(izb) = ntt(izb)
        to(izb) = t(izb)
        t(izb) = tt(izb)
        t9o(izb) = t9(izb)
        t9(izb) = t9t(izb)
        rhoo(izb) = rho(izb)
        rho(izb) = rhot(izb)
        yeo(izb) = ye(izb)
        ye(izb) = yet(izb)
        yo(:,izb) = y(:,izb)
        y(:,izb) = yt(:,izb)
        tdel_next(izb) = tdel(izb) * tdel_maxmult
      ElseIf ( inr(izb) == 0 ) Then
        its(izb) = 1
      EndIf
    EndDo

    ! Log TS success/failure
    Do izb = zb_lo, zb_hi
      izone = izb + szbatch - zb_lo
      If ( inr(izb) > 0 ) Then
        If ( idiag >= 2 ) Write(lun_diag,"(a,2i5,2i3)") &
          & 'BE TS Success',kstep,izone,mykts(izb),inr(izb)
      ElseIf ( inr(izb) == 0 ) Then
        If ( idiag >= 0 ) Write(lun_diag,"(a,2i5,4es12.4,2i3)") &
          & 'BE TS Fail',kstep,izone,t(izb),tdel(izb),t9t(izb),rhot(izb),inr(izb),mykts(izb)
        Write(lun_stdout,*) 'Timestep retrys fail after ',mykts(izb),' attempts'
      EndIf
    EndDo

    Do izb = zb_lo, zb_hi
      If ( inr(izb) >= 0 ) Then
        kmon(1,izb) = mykts(izb)
        ktot(1,izb) = ktot(1,izb) + mykts(izb)
      EndIf
    EndDo

    stop_timer = xnet_wtime()
    timer_tstep = timer_tstep + stop_timer

    Return
  End Subroutine solve_be

  Subroutine step_be(kstep,inr)
    !-----------------------------------------------------------------------------------------------
    ! This routine attempts to integrate a single Backward Euler step for the timestep tdel.
    ! If successful, inr = 1
    !-----------------------------------------------------------------------------------------------
    Use nuclear_data, Only: ny, aa, nname
    Use xnet_abundances, Only: y, ydot, yt, xext
    Use xnet_conditions, Only: cv, rhot, t9, t9dot, t9t, tdel, nh
    Use xnet_controls, Only: iconvc, idiag, iheat, ijac, kitmx, lun_diag, tolc, tolm, tolt9, ymin, &
      & szbatch, zb_lo, zb_hi, iscrn
    Use xnet_integrate, Only: cross_sect, yderiv
    Use xnet_jacobian, Only: jacobian_bksub, jacobian_decomp, jacobian_build, jacobian_solve
    Use xnet_timers, Only: xnet_wtime, start_timer, stop_timer, timer_nraph
    Use xnet_types, Only: dp
    Implicit None

    ! Input variables
    Integer, Intent(in) :: kstep

    ! Input/Output variables
    Integer, Intent(inout) :: inr(zb_lo:zb_hi) ! On input,  = 0 indicates active zone
                                               !            =-1 indicates inactive zone
                                               ! On output, > 0 indicates # NR iterations if converged

    ! Local variables
    Integer :: irdymx, idymx
    Integer :: i, k, kit, izb, izone
    Real(dp) :: testc, testc2, testm, testn(zb_lo:zb_hi), toln(zb_lo:zb_hi)
    Real(dp) :: xtot(zb_lo:zb_hi), xtot_init(zb_lo:zb_hi), rdt(zb_lo:zb_hi), mult(zb_lo:zb_hi)
    Real(dp) :: yrhs(ny,zb_lo:zb_hi), dy(ny,zb_lo:zb_hi), reldy(ny)
    Real(dp) :: t9rhs(zb_lo:zb_hi), dt9(zb_lo:zb_hi), relt9
    Logical :: iterate(zb_lo:zb_hi), eval_rates(zb_lo:zb_hi), rebuild(zb_lo:zb_hi)

    start_timer = xnet_wtime()
    timer_nraph = timer_nraph - start_timer

    ! Create mask for active zone integrations
    iterate = ( inr == 0 )

    ! Calculate initial total mass fraction
    Do izb = zb_lo, zb_hi
      If ( iterate(izb) ) Then
        xtot_init(izb) = sum(aa*y(:,izb)) + xext(izb) - 1.0
        rdt(izb) = 1.0 / tdel(izb)
        mult(izb) = -1.0
      Else
        xtot_init(izb) = 0.0
        rdt(izb) = 0.0
        mult(izb) = 0.0
      EndIf
    EndDo

    ! The Newton-Raphson iteration occurs for at most kitmx iterations.
    Do kit = 1, kitmx

      ! Rebuild and update LU factorization of the jacobian every ijac iterations
      rebuild = ( iterate .and. mod(kit-1,ijac) == 0 )

      ! If thermodynamic conditions are changing, rates need to be udpated
      If ( iheat > 0 ) Then
        eval_rates = iterate
      ElseIf ( kit == 1 ) Then
        eval_rates = ( iterate .and. nh(zb_lo:zb_hi) > 1 )
      Else
        eval_rates = .false.
      EndIf

      ! Calculate the reaction rates and abundance time derivatives
      Call cross_sect(mask_in = eval_rates)
      Call yderiv(mask_in = iterate)
      Call jacobian_build(diag_in = rdt,mult_in = mult,mask_in = rebuild)
      Call jacobian_decomp(kstep,mask_in = rebuild)

      ! Calculate equation to zero
      Do izb = zb_lo, zb_hi
        If ( iterate(izb) ) Then
          yrhs(:,izb) = (y(:,izb)-yt(:,izb))*rdt(izb) + ydot(:,izb)
          If ( iheat > 0 ) t9rhs(izb) = (t9(izb)*rdt(izb)-t9t(izb)*rdt(izb)) + t9dot(izb)
        EndIf
      EndDo
      If ( idiag >= 4 ) Then
        Do izb = zb_lo, zb_hi
          If ( iterate(izb) ) Then
            izone = izb + szbatch - zb_lo
            Write(lun_diag,"(a3,2i5,es14.7)") 'RHS',kstep,izone,rdt(izb)
            Write(lun_diag,"(a5,4es23.15)") (nname(i),yrhs(i,izb),ydot(i,izb),yt(i,izb),y(i,izb),i=1,ny)
            If ( iheat > 0 ) Write(lun_diag,"(a5,4es23.15)") 'T9',t9rhs(izb),t9dot(izb),t9t(izb),t9(izb)
          EndIf
        EndDo
      EndIf

      ! Solve the jacobian and calculate the changes in abundances, dy
      !Call jacobian_solve(kstep,yrhs,dy,t9rhs,dt9,mask_in = iterate)
      !Call jacobian_decomp(kstep,mask_in = iterate)
      Call jacobian_bksub(kstep,yrhs,dy,t9rhs,dt9,mask_in = iterate)

      ! Evolve the abundances and calculate convergence tests
      Do izb = zb_lo, zb_hi
        If ( iterate(izb) ) Then
          Do k = 1, ny
            yt(k,izb) = yt(k,izb) + dy(k,izb)
            If ( yt(k,izb) < ymin ) Then
              yt(k,izb) = 0.0
              reldy(k) = 0.0
            Else
              reldy(k) = abs(dy(k,izb) / yt(k,izb))
            EndIf
          EndDo
          If ( iheat > 0 ) Then
            t9t(izb) = t9t(izb) + dt9(izb)
            If ( abs(t9t(izb)) > tiny(0.0) ) Then
              relt9 = abs(dt9(izb) / t9t(izb))
            Else
              relt9 = 0.0
            EndIf
          Else
            relt9 = 0.0
          EndIf
          If ( idiag >= 4 ) Then
            izone = izb + szbatch - zb_lo
            irdymx = maxloc(reldy,dim=1)
            idymx = maxloc(dy(:,izb),dim=1)
            Write(lun_diag,"(a3,2i5,i3,2(a5,2es23.15))") &
              & ' dY',kstep,izone,kit,nname(idymx),dy(idymx,izb),y(idymx,izb),nname(irdymx),reldy(irdymx),y(irdymx,izb)
            If ( idiag >= 5 ) Write(lun_diag,"(a5,5es12.4)") &
              & (nname(k),yt(k,izb),dy(k,izb),reldy(k),(aa(k)*dy(k,izb)),(aa(k)*yt(k,izb)),k=1,ny)
            If ( iheat > 0 ) Write(lun_diag,"(a3,2i5,i3,5x,2es23.15,5x,es12.4)") &
              & 'dT9',kstep,izone,kit,dt9(izb),t9t(izb),relt9
          EndIf

          !-----------------------------------------------------------------------------------------
          ! There are 3 included convergence tests:
          ! testc which measures relative changes,
          ! testc2 which measures total abundance changes, and
          ! testm which tests mass conservation.
          !-----------------------------------------------------------------------------------------
          testc     = sum(reldy)
          testc2    = sum(aa*dy(:,izb))
          xtot(izb) = sum(aa*yt(:,izb)) + xext(izb) - 1.0
          testm     = xtot(izb) - xtot_init(izb)
          If ( idiag >= 3 ) Write(lun_diag,"(a,3i5,3es14.6)") 'NR',kstep,izone,kit,testm,testc,testc2

          !-----------------------------------------------------------------------------------------
          ! testc is the most stringent test, and requires the most iterations.
          ! testm is the most lax, and therefore the fastest, often requiring only one iteration.
          ! Considering the uncertainties of the reaction rates, it is doubtful that the
          ! increased precision of testc is truly increased accuracy.
          !-----------------------------------------------------------------------------------------
          ! Ordinarily, test for true convergence
          If ( iconvc /= 0 ) Then
            testn(izb) = testc
            toln(izb) = tolc

          ! Otherwise, use mass conservation for convergence condition
          Else
            testn(izb) = testm
            toln(izb) = tolm
          EndIf

          ! If converged, exit NR loop
          If ( abs(testn(izb)) <= toln(izb) .and. relt9 < tolt9 ) Then
            inr(izb) = kit
            iterate(izb) = .false.
          EndIf
        EndIf
      EndDo

      ! Check that all zones are converged
      If ( .not. any(iterate(:)) ) Exit
    EndDo

    If ( idiag >= 2 ) Then
      Do izb = zb_lo, zb_hi
        izone = izb + szbatch - zb_lo
        If ( inr(izb) > 0 ) Then
          Write(lun_diag,"(a,3i5,3es12.4)") 'Conv',kstep,izone,inr(izb),xtot(izb),testn(izb),toln(izb)
        ElseIf ( inr(izb) == 0 ) Then
          Write(lun_diag,"(a,3i5,2es10.2)") 'BE Failure',izone,inr(izb),kitmx,xtot(izb),testn(izb)
        EndIf
      EndDo
    EndIf

    stop_timer = xnet_wtime()
    timer_nraph = timer_nraph + stop_timer

    Return
  End Subroutine step_be

End Module xnet_integrate_be
